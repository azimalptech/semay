// End-to-end load harness for the API. Measures the real HTTP and WebSocket
// paths — Fastify, auth middleware, Prisma, MySQL, the realtime bus — not a
// synthetic query benchmark.
//
// Everything it creates is tagged with MARK and removed at the end, including
// on Ctrl-C, so it can be pointed at the working database without leaving
// residue.
//
//   node --env-file=.env scripts/loadtest.mjs [options]
//
//     --posts 5000        posts to seed before the read scenarios
//     --requests 600      requests per HTTP scenario
//     --sockets 2000      concurrent WebSocket connections to open
//     --api http://…      base URL (default http://127.0.0.1:8080/api/v1)
//
// Point --api at a throwaway instance started with a raised
// RATE_LIMIT_MAX_PER_MIN. Against the real service the global per-IP cap (3000
// req/min by design) throttles the harness itself and the numbers measure the
// rate limiter rather than the endpoints.
import { PrismaClient } from "@prisma/client";
import WebSocket from "ws";

import { signAccessToken } from "../dist/lib/jwt.js";

const prisma = new PrismaClient();
const MARK = "__LOAD_TEST__";

const argIdx = (name) => process.argv.indexOf(`--${name}`);
const num = (name, dflt) => {
  const i = argIdx(name);
  return i === -1 ? dflt : Number(process.argv[i + 1]);
};
const str = (name, dflt) => {
  const i = argIdx(name);
  return i === -1 ? dflt : process.argv[i + 1];
};

const POSTS = num("posts", 5000);
const REQUESTS = num("requests", 600);
const SOCKETS = num("sockets", 2000);
// Seconds to keep the socket pool open after it fills, so the server's resident
// memory can be sampled while the connections are actually held.
const HOLD = num("hold", 0);
const SKIP_HTTP = argIdx("skip-http") !== -1;
const API = str("api", "http://127.0.0.1:8080/api/v1");
const WS_URL = `${API.replace(/^http/, "ws")}/ws`;

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

function stats(label, concurrency, latencies, elapsedSec, statuses) {
  const sorted = [...latencies].sort((a, b) => a - b);
  return {
    label,
    concurrency,
    rps: sorted.length / elapsedSec,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
    max: sorted.at(-1) ?? 0,
    statuses,
  };
}

/** Fires `total` requests keeping `concurrency` in flight, returning latency
 * stats. Sustained concurrency is the point: average latency of sequential
 * requests says nothing about behaviour under real load. */
async function run(label, concurrency, total, makeRequest) {
  const latencies = [];
  // Counting failures without their status code makes a rate-limited run look
  // identical to a broken endpoint — the first version of this harness reported
  // "600 failures" on two scenarios that were in fact working perfectly and
  // simply being throttled.
  const codes = new Map();
  const note = (k) => codes.set(k, (codes.get(k) ?? 0) + 1);

  let issued = 0;
  const started = performance.now();

  async function worker() {
    for (;;) {
      if (issued >= total) return;
      issued++;
      const t0 = performance.now();
      try {
        const res = await makeRequest();
        note(res.status);
        await res.arrayBuffer(); // drain, or sockets pile up and skew timings
      } catch (err) {
        note(err?.cause?.code ?? "network");
      }
      latencies.push(performance.now() - t0);
    }
  }

  await Promise.all(Array.from({ length: concurrency }, worker));
  const elapsed = (performance.now() - started) / 1000;
  const summary = [...codes.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([k, v]) => `${k}×${v}`)
    .join(" ");
  return stats(label, concurrency, latencies, elapsed, summary);
}

function report(rows) {
  const w = 28;
  console.log(
    `\n${"scenario".padEnd(w)}${"conc".padStart(6)}${"req/s".padStart(9)}` +
      `${"p50 ms".padStart(9)}${"p95 ms".padStart(9)}${"p99 ms".padStart(9)}` +
      `${"max ms".padStart(9)}  outcomes`
  );
  console.log("-".repeat(w + 51 + 20));
  for (const r of rows) {
    console.log(
      r.label.padEnd(w) +
        String(r.concurrency).padStart(6) +
        r.rps.toFixed(0).padStart(9) +
        r.p50.toFixed(1).padStart(9) +
        r.p95.toFixed(1).padStart(9) +
        r.p99.toFixed(1).padStart(9) +
        r.max.toFixed(1).padStart(9) +
        "  " +
        r.statuses
    );
  }
}

async function cleanup() {
  const stores = await prisma.store.findMany({ where: { name: MARK }, select: { id: true } });
  const ids = stores.map((s) => s.id);
  if (ids.length) {
    await prisma.order.deleteMany({ where: { storeId: { in: ids } } });
    await prisma.store.deleteMany({ where: { id: { in: ids } } }); // cascades posts/chats
  }
  await prisma.user.deleteMany({ where: { name: MARK } });
}

/** Access tokens are signed locally rather than obtained through the OTP flow:
 * the flow needs a real SMS round-trip per user and is deliberately rate
 * limited, which makes it unusable for seeding thousands of clients. The token
 * shape and secret are the server's own, so every request still traverses the
 * full auth middleware exactly as a real client's would. */
function tokenFor(user, storeIds = []) {
  return signAccessToken({
    userId: user.id,
    role: user.role,
    storeIds,
    claimsVersion: user.claimsVersion ?? 0,
  });
}

// Sequential, not random: `phone` is UNIQUE, and 200 random 6-digit numbers
// carry a real birthday-collision chance that would abort a run mid-seed. The
// +99399 prefix is not an allocated Turkmen mobile range, so these cannot
// shadow a genuine account.
let phoneSeq = 0;
const phone = () => `+99399${String(phoneSeq++).padStart(7, "0")}`;

/** Opens `count` sockets, each subscribing to its own chat channel, and reports
 * how long the handshake+subscribe round trip takes as the pool fills. This is
 * the number that decides how many concurrent app sessions one process holds:
 * every foregrounded app keeps a socket open, so it is the capacity ceiling
 * that binds first, well before request throughput does. */
async function socketStorm(count, entries) {
  const connectLatencies = [];
  const errors = new Map();
  const sockets = [];
  const note = (k) => errors.set(k, (errors.get(k) ?? 0) + 1);

  const started = performance.now();
  let opened = 0;

  await new Promise((resolve) => {
    let settled = 0;
    const done = () => {
      settled++;
      if (settled >= count) resolve();
    };

    for (let i = 0; i < count; i++) {
      const entry = entries[i % entries.length];
      const t0 = performance.now();
      let ws;
      try {
        ws = new WebSocket(`${WS_URL}?token=${encodeURIComponent(entry.token)}`);
      } catch (err) {
        note(err?.code ?? "spawn-failed");
        done();
        continue;
      }
      sockets.push(ws);
      let settledThis = false;
      const settle = (key) => {
        if (settledThis) return;
        settledThis = true;
        if (key) note(key);
        done();
      };

      ws.on("open", () => {
        opened++;
        ws.send(JSON.stringify({ type: "subscribe", channel: `chat:${entry.chatId}:messages` }));
      });
      // Measure to first snapshot, not to "open": an open socket that never gets
      // its snapshot back is not a usable session.
      ws.once("message", () => {
        connectLatencies.push(performance.now() - t0);
        settle(null);
      });
      ws.on("error", (err) => settle(err?.code ?? "ws-error"));
      ws.on("close", (code) => settle(code === 1000 ? null : `close-${code}`));
    }
  });

  const elapsed = (performance.now() - started) / 1000;
  const live = sockets.filter((s) => s.readyState === WebSocket.OPEN);

  // Fan-out latency: publish one message and time how long a subscribed socket
  // takes to see it while the whole pool is connected.
  let fanout = null;
  if (live.length > 0) {
    const entry = entries[0];
    const watcher = sockets.find((s) => s.readyState === WebSocket.OPEN);
    fanout = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), 5000);
      watcher.once("message", () => {
        clearTimeout(timer);
        resolve(performance.now() - t1);
      });
      const t1 = performance.now();
      fetch(`${API}/chats/${entry.chatId}/messages`, {
        method: "POST",
        headers: { Authorization: `Bearer ${entry.token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ text: `${MARK} fanout probe` }),
      }).catch(() => {});
    });
  }

  if (HOLD > 0) {
    console.log(`  holding ${live.length} sockets open for ${HOLD}s (sample server RSS now)…`);
    await new Promise((r) => setTimeout(r, HOLD * 1000));
  }

  for (const s of sockets) s.terminate();

  return {
    requested: count,
    opened,
    snapshots: connectLatencies.length,
    live: live.length,
    elapsed,
    p50: percentile([...connectLatencies].sort((a, b) => a - b), 50),
    p95: percentile([...connectLatencies].sort((a, b) => a - b), 95),
    max: [...connectLatencies].sort((a, b) => a - b).at(-1) ?? 0,
    errors: [...errors.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}×${v}`).join(" "),
    fanout,
  };
}

async function main() {
  let interrupted = false;
  process.on("SIGINT", async () => {
    if (interrupted) process.exit(130);
    interrupted = true;
    console.log("\ninterrupted — cleaning up");
    await cleanup().catch(() => {});
    await prisma.$disconnect();
    process.exit(130);
  });

  await cleanup(); // clear anything a previous interrupted run left

  const health = await fetch(`${API.replace("/api/v1", "")}/health`).catch(() => null);
  if (!health?.ok) throw new Error(`API not reachable at ${API} — start it first`);

  // ---- seed -------------------------------------------------------------
  const owner = await prisma.user.create({
    data: { phone: phone(), name: MARK, role: "admin" },
  });
  const store = await prisma.store.create({ data: { name: MARK, createdById: owner.id } });
  await prisma.storeAdmin.create({ data: { storeId: store.id, userId: owner.id } }).catch(() => {});
  const adminToken = tokenFor(owner, [store.id]);

  console.log(`seeding ${POSTS} posts…`);
  const now = Date.now();
  for (let i = 0; i < POSTS; i += 1000) {
    const chunk = Math.min(1000, POSTS - i);
    await prisma.post.createMany({
      data: Array.from({ length: chunk }, (_, k) => ({
        storeId: store.id,
        type: (i + k) % 3 === 2 ? "reel" : "image",
        caption: `load test post ${i + k}`,
        thumbnailUrl: "",
        // Spread createdAt so the feed's ORDER BY has real work to do.
        createdAt: new Date(now - (i + k) * 1000),
      })),
    });
  }
  const totalPosts = await prisma.post.count();
  const postRows = await prisma.post.findMany({
    where: { storeId: store.id },
    select: { id: true },
    take: 500,
  });
  const postIds = postRows.map((p) => p.id);
  const samplePostId = postIds[0];

  // A pool of real users, each with a real chat — the WS and write scenarios
  // need distinct identities or they measure one hot row instead of the system.
  const USERS = Math.min(200, Math.max(20, Math.ceil(SOCKETS / 10)));
  console.log(`seeding ${USERS} users + chats…`);
  const entries = [];
  for (let i = 0; i < USERS; i++) {
    const u = await prisma.user.create({ data: { phone: phone(), name: MARK, role: "user" } });
    // Chat ids are deterministic (`${userId}_${storeId}`, see chats/service.ts)
    // and the column has no DB default, so seeding must use the same shape.
    const chat = await prisma.chat.create({
      data: { id: `${u.id}_${store.id}`, userId: u.id, storeId: store.id },
    });
    entries.push({ userId: u.id, chatId: chat.id, token: tokenFor(u) });
  }
  console.log(`posts in DB: ${totalPosts}; chats: ${entries.length}\n`);

  const rows = [];
  // Every scenario rotates through the seeded identities rather than reusing
  // one token. A single hot user would let per-user caches and MySQL's buffer
  // pool answer from one warm row set and overstate throughput.
  let n = 0;
  const next = () => entries[n++ % entries.length];
  const get = (path) => {
    const e = next();
    return fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${e.token}` } });
  };

  if (!SKIP_HTTP) {
    // Warm the pool and the query plan so the first scenario isn't penalised.
    await run("warmup", 10, 100, () => get("/feed?limit=20"));

    // ---- read paths -----------------------------------------------------
    for (const c of [1, 10, 50, 100]) {
      rows.push(await run("GET /feed (page 1)", c, REQUESTS, () => get("/feed?limit=20")));
    }
    rows.push(
      await run("GET /feed (offset 500)", 50, REQUESTS, () => get("/feed?limit=20&offset=500"))
    );
    rows.push(await run("GET /reels", 50, REQUESTS, () => get("/reels?limit=20")));
    rows.push(await run("GET /stores", 50, REQUESTS, () => get("/stores")));

    // Per-user paths — what the app actually hits on launch.
    rows.push(await run("GET /chats (as user)", 50, REQUESTS, () => get("/chats")));
    // The store-admin inbox is a different query (listStoreChats, ordered over
    // every chat in the store) and is polled far more often per account.
    rows.push(
      await run("GET /chats (store admin)", 50, REQUESTS, () =>
        fetch(`${API}/chats?storeId=${store.id}`, {
          headers: { Authorization: `Bearer ${adminToken}` },
        })
      )
    );
    rows.push(
      await run("GET /chats/:id/messages", 50, REQUESTS, () => {
        const e = next();
        return fetch(`${API}/chats/${e.chatId}/messages?limit=50`, {
          headers: { Authorization: `Bearer ${e.token}` },
        });
      })
    );

    // ---- write paths ----------------------------------------------------
    rows.push(
      await run("POST message (write)", 50, REQUESTS, () => {
        const e = next();
        return fetch(`${API}/chats/${e.chatId}/messages`, {
          method: "POST",
          headers: { Authorization: `Bearer ${e.token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ text: `${MARK} ${Math.random()}` }),
        });
      })
    );
    rows.push(
      await run("POST interactions (flush)", 50, REQUESTS, () => {
        const e = next();
        return fetch(`${API}/posts/interactions`, {
          method: "POST",
          headers: { Authorization: `Bearer ${e.token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ items: [{ postId: samplePostId, views: 1 }] }),
        });
      })
    );
    // Deliberately all on ONE post: like/unlike is the highest-concurrency
    // write in the product, and a post going viral means thousands of users
    // hitting the same row (and the same store row it rolls up to) at once.
    // Alternating on/off keeps every request doing real work rather than
    // short-circuiting on the duplicate-key fast path.
    let flip = 0;
    rows.push(
      await run("POST/DELETE like (1 post)", 50, REQUESTS, () => {
        const e = next();
        const on = flip++ % 2 === 0;
        return fetch(`${API}/posts/${samplePostId}/like`, {
          method: on ? "POST" : "DELETE",
          headers: { Authorization: `Bearer ${e.token}` },
        });
      })
    );
    // The same write spread over many posts — the ordinary case. Row locks are
    // per post, so this should be far faster than the single-post row above;
    // if it is not, the contention is somewhere other than the post row and the
    // lock ordering needs re-examining.
    rows.push(
      await run("POST/DELETE like (spread)", 50, REQUESTS, () => {
        const e = next();
        const i = flip++;
        return fetch(`${API}/posts/${postIds[i % postIds.length]}/like`, {
          method: i % 2 === 0 ? "POST" : "DELETE",
          headers: { Authorization: `Bearer ${e.token}` },
        });
      })
    );

    report(rows);
  }

  // ---- realtime ---------------------------------------------------------
  console.log(`\nopening ${SOCKETS} concurrent WebSocket sessions…`);
  const ws = await socketStorm(SOCKETS, entries);
  console.log(
    `  requested ${ws.requested}  opened ${ws.opened}  snapshot-ready ${ws.snapshots}  ` +
      `still live ${ws.live}`
  );
  console.log(
    `  connect+snapshot  p50 ${ws.p50.toFixed(0)}ms  p95 ${ws.p95.toFixed(0)}ms  ` +
      `max ${ws.max.toFixed(0)}ms  over ${ws.elapsed.toFixed(1)}s`
  );
  if (ws.errors) console.log(`  socket errors: ${ws.errors}`);
  console.log(
    `  fan-out (publish → subscriber receives): ${ws.fanout === null ? "TIMED OUT" : `${ws.fanout.toFixed(0)}ms`}`
  );

  await cleanup();
  console.log("\ncleaned up load-test data");
  await prisma.$disconnect();
}

main().catch(async (e) => {
  console.error(e);
  await cleanup().catch(() => {});
  await prisma.$disconnect();
  process.exit(1);
});
