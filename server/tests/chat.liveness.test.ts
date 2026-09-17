import { connect as netConnect, createServer, type AddressInfo, type Server, type Socket } from "node:net";

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import WebSocket from "ws";

import { createOrGetChat } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { closeBus as closeFixtureBus } from "../src/realtime/bus.js";
import {
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  refreshedToken,
} from "./helpers.js";

// Hoisted above every import: config.ts reads the environment once, when it is
// first imported, and helpers.ts pulls it in statically. A 3 s access token
// lets one test span two expiries in eight seconds.
vi.hoisted(() => {
  process.env.ACCESS_TOKEN_TTL_SECONDS = "3";
});

// Chat liveness contracts, over a real listener and real sockets (CLAUDE.md
// rule 9 — inject() never touches the gateway). The report behind them:
// "messages stop appearing after a couple, until I reopen the app". Two
// things were checked. Token expiry across an open socket is NOT it (block 1
// proves it). A REDIS_URL pointing at nothing IS: ioredis queued every publish
// in memory, SUBSCRIBE never settled so no snapshot ever went out, every
// error was swallowed and /health/ready only asked the DB — sockets stayed
// open and answered pings while nothing arrived. Blocks 2–4 pin the fix:
// in-process delivery whenever Redis is not confirmed live, a snapshot that
// never waits on a dead Redis, and a readiness body that says so.
//
// Every block boots its own server from a fresh module graph (vi.resetModules)
// so each can have its own REDIS_URL; helpers.ts keeps the original graph for
// fixtures.

interface Frame {
  channel?: string;
  type: string;
  data?: unknown;
  error?: string;
}

interface Client {
  ws: WebSocket;
  next: (pred: (f: Frame) => boolean, timeoutMs?: number) => Promise<Frame>;
  frames: Frame[];
  closed: () => boolean;
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

async function until(cond: () => boolean, ms: number, what: string): Promise<void> {
  const deadline = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`timed out after ${ms} ms waiting for ${what}`);
    await sleep(25);
  }
}

async function connectSocket(port: number, token: string): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/api/v1/ws?token=${token}`);
  const frames: Frame[] = [];
  const waiters: { pred: (f: Frame) => boolean; resolve: (f: Frame) => void }[] = [];
  let closed = false;
  ws.on("close", () => {
    closed = true;
  });
  ws.on("message", (raw) => {
    const frame = JSON.parse(raw.toString()) as Frame;
    frames.push(frame);
    const i = waiters.findIndex((w) => w.pred(frame));
    if (i !== -1) waiters.splice(i, 1)[0]!.resolve(frame);
  });
  await new Promise<void>((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
  const next = (pred: (f: Frame) => boolean, timeoutMs = 10_000): Promise<Frame> => {
    const already = frames.find(pred);
    if (already) {
      frames.splice(frames.indexOf(already), 1);
      return Promise.resolve(already);
    }
    return new Promise<Frame>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out waiting for frame")), timeoutMs);
      waiters.push({
        pred,
        resolve: (f) => {
          clearTimeout(timer);
          frames.splice(frames.indexOf(f), 1);
          resolve(f);
        },
      });
    });
  };
  return { ws, next, frames, closed: () => closed };
}

/** A port nothing listens on — bound once and released, so a hard-coded
 * "dead" port can never collide with something that happens to be running. */
async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address() as AddressInfo;
      srv.close(() => resolve(port));
    });
  });
}

function tcpOpen(host: string, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const s = netConnect(port, host);
    s.setTimeout(1500);
    s.once("connect", () => {
      s.destroy();
      resolve(true);
    });
    s.once("error", () => resolve(false));
    s.once("timeout", () => {
      s.destroy();
      resolve(false);
    });
  });
}

/** A TCP relay in front of the real Redis that the test can kill and bring
 * back: stopping it drops every live connection and refuses new ones, which is
 * what a Redis restart looks like from the server. The local Redis service
 * itself is shared with the developer's other work and is never touched. */
class RedisProxy {
  private server: Server | undefined;
  private readonly sockets = new Set<Socket>();

  constructor(
    readonly port: number,
    private readonly target: { host: string; port: number }
  ) {}

  async start(): Promise<void> {
    const server = createServer((client) => {
      const upstream = netConnect(this.target.port, this.target.host);
      this.sockets.add(client).add(upstream);
      client.pipe(upstream).pipe(client);
      const drop = (): void => {
        client.destroy();
        upstream.destroy();
        this.sockets.delete(client);
        this.sockets.delete(upstream);
      };
      for (const s of [client, upstream]) {
        s.on("close", drop);
        s.on("error", drop);
      }
    });
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(this.port, "127.0.0.1", () => resolve());
    });
  }

  async stop(): Promise<void> {
    for (const s of this.sockets) s.destroy();
    this.sockets.clear();
    const server = this.server;
    this.server = undefined;
    await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()));
  }
}

/** Boots the server from a fresh module graph with the given environment. */
async function boot(env: Record<string, string>) {
  vi.unstubAllEnvs();
  vi.resetModules();
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
  const [{ buildApp }, chats, db, bus, jwt] = await Promise.all([
    import("../src/app.js"),
    import("../src/chats/service.js"),
    import("../src/db.js"),
    import("../src/realtime/bus.js"),
    import("../src/lib/jwt.js"),
  ]);
  const app = await buildApp();
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = (app.server.address() as AddressInfo).port;
  return {
    port,
    chats,
    db,
    bus,
    jwt,
    async close(): Promise<void> {
      await app.close();
      await bus.closeBus();
      await db.disconnectDb();
    },
  };
}
type Booted = Awaited<ReturnType<typeof boot>>;

async function healthBody(
  port: number,
  path: string
): Promise<{ status: number; body: Record<string, unknown> }> {
  const res = await fetch(`http://127.0.0.1:${port}${path}`);
  return { status: res.status, body: (await res.json()) as Record<string, unknown> };
}

/** The load balancer's path. Reports the bus, never fails on it (app.ts). */
async function readyBody(port: number): Promise<{ status: number; body: Record<string, unknown> }> {
  return healthBody(port, "/health/ready");
}

/** The fail-CLOSED half, split out of /health/ready so a shared-Redis outage
 * takes realtime out of rotation instead of the whole API (app.ts). */
async function realtimeBody(
  port: number
): Promise<{ status: number; body: Record<string, unknown> }> {
  return healthBody(port, "/health/realtime");
}

const REAL_REDIS = process.env.REDIS_URL || "redis://127.0.0.1:6379";
const realRedis = new URL(REAL_REDIS);
const realTarget = { host: realRedis.hostname, port: Number(realRedis.port || 6379) };
const redisUp = await tcpOpen(realTarget.host, realTarget.port);
const deadPort = await freePort();

let userId: string;
let adminId: string;
let storeId: string;
let chatId: string;

beforeAll(async () => {
  ({ userId } = await createUserWithToken("user"));
  ({ userId: adminId } = await createUserWithToken("admin"));
  const store = await createStore("Liveness Test Store", adminId);
  storeId = store.id;
  await prisma.storeAdmin.create({ data: { userId: adminId, storeId } });
  chatId = (await createOrGetChat(userId, storeId)).id;
});

afterAll(async () => {
  await cleanupStores([storeId]);
  await cleanupUsers([userId, adminId]);
  await closeFixtureBus();
  vi.unstubAllEnvs();
});

/** Opens the thread the way the phone does and asserts the snapshot arrives. */
async function openThread(b: Booted): Promise<{ client: Client; channel: string; snapshotMs: number }> {
  const client = await connectSocket(b.port, await refreshedToken(userId));
  const channel = `chat:${chatId}:messages`;
  const t0 = Date.now();
  client.ws.send(JSON.stringify({ type: "subscribe", channel }));
  const snapshot = await client.next((f) => f.channel === channel && f.type === "snapshot");
  expect(Array.isArray(snapshot.data)).toBe(true);
  return { client, channel, snapshotMs: Date.now() - t0 };
}

/** How long a published message may take to reach an open socket before the
 * thread counts as frozen. Generous on purpose: this file proves LIVENESS, not
 * latency, and a ceiling that doubles as a benchmark is a gate that goes red
 * for being run on a busy machine.
 *
 * It is measured from the moment `sendMessage` RESOLVES, not from the moment it
 * is called. The difference is the whole point. The reported defect is
 * "messages stop appearing" — a publish that never reaches the socket — and
 * `publish()` delivers to this process's own listeners synchronously
 * (src/realtime/bus.ts deliverLocal), so the number that can regress here is
 * sub-millisecond. Timing from before the call instead put the `withRetry`ed
 * `prisma.$transaction` with its `SELECT … FOR UPDATE` (src/chats/service.ts)
 * inside the budget, so the assertion was really measuring how contended the
 * database was: it read 4-7 ms idle and 1.3-2.4 s with the rest of the suite
 * running in parallel, and failed 20-50% of full runs under a "took 1305 ms"
 * message that reads like a realtime regression and never was one. */
const DELIVER_CEILING_MS = 5_000;

/** Sends `count` admin messages `gapMs` apart and requires each one to reach
 * the open thread as a live upsert — in order, on the right channel, without
 * the socket closing, and within DELIVER_CEILING_MS of the send completing.
 *
 * Returns the worst delivery seen so a caller can assert on the whole block. */
async function sendLive(
  b: Booted,
  client: Client,
  channel: string,
  count: number,
  gapMs: number,
  label: string
): Promise<{ ids: bigint[]; maxDeliverMs: number }> {
  const ids: bigint[] = [];
  let maxDeliverMs = 0;
  for (let i = 0; i < count; i++) {
    const chat = await b.db.prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    const sent = await b.chats.sendMessage(chat, "admin", adminId, { text: `${label} #${i}` });
    // The clock starts here: the row is committed and publish() has already
    // run, so everything after this point is delivery.
    const publishedAt = Date.now();
    await client.next(
      (f) =>
        f.channel === channel &&
        f.type === "upsert" &&
        String((f.data as { id: string }).id) === sent.id.toString(),
      DELIVER_CEILING_MS
    );
    // Frames that landed while sendMessage was still resolving are already
    // queued, and clamp to 0 — they arrived, which is the contract.
    const deliverMs = Math.max(0, Date.now() - publishedAt);
    expect(deliverMs, `${label} #${i} delivered in ${deliverMs} ms`).toBeLessThan(
      DELIVER_CEILING_MS
    );
    expect(client.closed(), `${label} #${i}: the socket closed mid-stream`).toBe(false);
    maxDeliverMs = Math.max(maxDeliverMs, deliverMs);
    ids.push(sent.id);
    if (gapMs > 0) await sleep(gapMs);
  }
  return { ids, maxDeliverMs };
}

function expectAscending(ids: bigint[]): void {
  for (let i = 1; i < ids.length; i++) expect(ids[i]! > ids[i - 1]!).toBe(true);
}

describe("chat stays live across access-token expiry (TTL 3 s)", () => {
  let b: Booted;

  beforeAll(async () => {
    b = await boot({ REDIS_URL: REAL_REDIS });
  });

  afterAll(async () => {
    await b.close();
  });

  it("20 upserts over more than two TTLs arrive live, in order, with the socket never closing", async () => {
    // The gateway verifies the token once, at the handshake; nothing on the
    // socket's lifetime depends on it staying valid. This pins that so a
    // future "re-verify on every frame" cannot quietly turn every expiry into
    // a frozen thread.
    const { client, channel } = await openThread(b);
    const token = client.ws.url.split("token=")[1]!;
    const t0 = Date.now();
    const { ids, maxDeliverMs } = await sendLive(b, client, channel, 20, 400, "ttl");
    expect(Date.now() - t0).toBeGreaterThanOrEqual(2 * 3_000);
    expect(ids).toHaveLength(20);
    expectAscending(ids);
    // Not a benchmark — the point is that the LAST upsert, four token
    // expiries in, is delivered as promptly as the first.
    expect(maxDeliverMs).toBeLessThan(DELIVER_CEILING_MS);
    expect(() => b.jwt.verifyAccessToken(token)).toThrow(/expired/i);
    expect(client.closed()).toBe(false);
    expect(client.frames.filter((f) => f.type === "snapshot")).toEqual([]);

    // The app's resume-from-background probe still works with an expired token.
    client.ws.send(JSON.stringify({ type: "ping" }));
    await client.next((f) => f.type === "pong", 2_000);
    client.ws.close();
  }, 30_000);
});

describe.skipIf(!redisUp)(`a Redis outage mid-stream (real Redis at ${realTarget.host}:${realTarget.port} behind a killable relay)`, () => {
  let proxy: RedisProxy;
  let b: Booted;

  beforeAll(async () => {
    proxy = new RedisProxy(await freePort(), realTarget);
    await proxy.start();
    b = await boot({ REDIS_URL: `redis://127.0.0.1:${proxy.port}` });
  });

  afterAll(async () => {
    await b.close();
    await proxy.stop();
  });

  it("loses nothing: in-process delivery while Redis is down, Redis delivery again once it is back", async () => {
    const spy = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
    b.bus.bindBusLogger(spy);
    expect(await b.bus.verifyBusAtBoot()).toBeNull();
    expect(b.bus.busHealth()).toMatchObject({ mode: "redis", ready: true, droppedPublishes: 0 });

    const { client, channel } = await openThread(b);
    const before = await sendLive(b, client, channel, 5, 0, "before");

    await proxy.stop();
    await until(() => !b.bus.busHealth().ready, 3_000, "the bus to notice the drop");
    const during = await sendLive(b, client, channel, 5, 0, "during");
    // The first reconnect attempt is what produces the refused-connection
    // error naming the host; the drop itself is only a close.
    await until(
      () => (b.bus.busHealth().lastError ?? "").includes(`127.0.0.1:${proxy.port}`),
      5_000,
      "a reconnect attempt to be refused"
    );
    const down = b.bus.busHealth();
    expect(down.ready).toBe(false);
    // One message publishes on several channels (thread, chat document, both
    // chat lists), so count what went in-process rather than assume 1:1.
    const droppedDuring = down.droppedPublishes;
    expect(droppedDuring).toBeGreaterThanOrEqual(during.ids.length);
    expect(down.lastErrorAt).not.toBeNull();
    const readyWhileDown = await readyBody(b.port);
    // Single process: degraded, not failed — every socket is on this process.
    expect(readyWhileDown.status).toBe(200);
    expect(readyWhileDown.body).toMatchObject({ ok: true, db: true, degraded: true });
    expect(readyWhileDown.body.bus).toMatchObject({ mode: "redis", ready: false, droppedPublishes: droppedDuring });
    expect(spy.warn).toHaveBeenCalledWith(
      expect.objectContaining({ redis: `127.0.0.1:${proxy.port}` }),
      expect.stringContaining("Redis connection lost")
    );
    expect(spy.error).toHaveBeenCalledWith(
      expect.objectContaining({ redis: `127.0.0.1:${proxy.port}` }),
      expect.stringContaining("Redis error")
    );

    await proxy.start();
    await until(() => b.bus.busHealth().ready, 15_000, "the bus to reconnect");
    expect(spy.warn).toHaveBeenCalledWith(
      expect.objectContaining({ droppedPublishes: droppedDuring }),
      expect.stringContaining("Redis reconnected")
    );
    const after = await sendLive(b, client, channel, 5, 0, "after");
    // Unchanged: the last five went through Redis, not the fallback.
    expect(b.bus.busHealth().droppedPublishes).toBe(droppedDuring);
    expect((await readyBody(b.port)).body).toMatchObject({ ok: true, degraded: false });

    expectAscending([...before.ids, ...during.ids, ...after.ids]);
    expect(client.closed()).toBe(false);
    expect(client.frames.filter((f) => f.type === "snapshot")).toEqual([]);
    // EXACTLY before+during+after, never a duplicate. `next` removes each
    // frame it matched, so anything still queued on this channel is a second
    // copy of a message already delivered. That was reachable while publish()
    // decided local-vs-echo from `subscriberLive`: ioredis restores its own
    // confirmed subscriptions before resubscribeAll() flips that flag, so a
    // publish in the window took both paths. Publishes are now tagged with
    // the originating process and the echo of our own is dropped on receipt
    // (bus.ts), which has no such window.
    expect(client.frames.filter((f) => f.channel === channel && f.type === "upsert")).toEqual([]);
    client.ws.close();
  }, 40_000);
});

describe("REDIS_URL set but nothing listening", () => {
  let b: Booted;

  beforeAll(async () => {
    b = await boot({ REDIS_URL: `redis://127.0.0.1:${deadPort}` });
  });

  afterAll(async () => {
    await b.close();
  });

  it("boot logs one error-level line naming the host, and returns the problem for cluster.ts", async () => {
    const spy = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
    b.bus.bindBusLogger(spy);
    const problem = await b.bus.verifyBusAtBoot();
    expect(problem).toContain(`127.0.0.1:${deadPort}`);
    const unreachable = spy.error.mock.calls.filter(([, msg]) => /Redis is unreachable/.test(String(msg)));
    expect(unreachable).toHaveLength(1);
    expect(unreachable[0]![0]).toMatchObject({ redis: `127.0.0.1:${deadPort}` });
    expect(spy.info).not.toHaveBeenCalledWith(expect.anything(), expect.stringContaining("Redis pub-sub"));
  }, 15_000);

  it("subscribe → snapshot within 3 s, upserts live, /health/ready reports the dead bus", async () => {
    // Before: the snapshot never came (SUBSCRIBE pending forever), the upsert
    // never came (queued in ioredis's offline queue), ping still pong'd, and
    // /health/ready said {ok:true}.
    const { client, channel, snapshotMs } = await openThread(b);
    expect(snapshotMs).toBeLessThan(3_000);
    const { ids } = await sendLive(b, client, channel, 3, 0, "dead");
    expect(ids).toHaveLength(3);

    const ready = await readyBody(b.port);
    expect(ready.status).toBe(200);
    expect(ready.body).toMatchObject({ ok: true, db: true, degraded: true });
    const bus = ready.body.bus as { mode: string; ready: boolean; droppedPublishes: number };
    expect(bus.mode).toBe("redis");
    expect(bus.ready).toBe(false);
    expect(bus.droppedPublishes).toBeGreaterThanOrEqual(3);
    // The host:port and the raw ioredis message stay OFF this unauthenticated
    // body (app.ts) and are read from busHealth() / the log line instead.
    expect(bus).not.toHaveProperty("lastError");
    expect(bus).not.toHaveProperty("lastErrorAt");
    expect(b.bus.busHealth().lastError).toContain(`127.0.0.1:${deadPort}`);
    client.ws.close();
  });
});

describe("REDIS_REQUIRED=true: realtime readiness fails closed once the bus has been gone for the grace period", () => {
  let b: Booted;

  beforeAll(async () => {
    b = await boot({ REDIS_URL: `redis://127.0.0.1:${deadPort}`, REDIS_REQUIRED: "true" });
  });

  afterAll(async () => {
    vi.useRealTimers();
    await b.close();
  });

  // Which ENDPOINT fails closed is the whole point of the split in app.ts:
  // /health/ready is what an HTTP load balancer polls, and failing it on the
  // bus turns a realtime outage into a total one — every box sharing one Redis
  // crosses the grace together and the balancer is left with no backend for
  // login, feed, stores, orders or media, none of which need Redis.
  // /health/realtime carries the fail-closed verdict instead.
  it("200 degraded inside the 30 s grace; after it /health/ready still serves and /health/realtime is 503", async () => {
    const early = await readyBody(b.port);
    expect(early.status).toBe(200);
    expect(early.body).toMatchObject({ ok: true, degraded: true, realtime: true });
    expect((await realtimeBody(b.port)).status).toBe(200);

    // Only the clock moves; timers, sockets and the DB stay real.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + 31_000);
    const late = await readyBody(b.port);
    const lateRealtime = await realtimeBody(b.port);
    vi.useRealTimers();
    // The API keeps serving — and says plainly that realtime is gone.
    expect(late.status).toBe(200);
    expect(late.body).toMatchObject({ ok: true, db: true, degraded: true, realtime: false });
    expect(late.body.bus).toMatchObject({ mode: "redis", ready: false });
    // The realtime upstream's probe is the one that goes out of rotation.
    expect(lateRealtime.status).toBe(503);
    expect(lateRealtime.body).toMatchObject({ ok: false, required: true, degraded: true });
  });
});

describe("REDIS_REQUIRED=true: a worker that cannot deliver stops pretending to", () => {
  let b: Booted;

  beforeAll(async () => {
    b = await boot({ REDIS_URL: `redis://127.0.0.1:${deadPort}`, REDIS_REQUIRED: "true" });
  });

  afterAll(async () => {
    vi.useRealTimers();
    await b.close();
  });

  // The half that /health/ready alone cannot cover. Readiness turning 503
  // stops a load balancer sending NEW connections here; it does not close the
  // WebSockets already attached, and those are the phones with a thread open.
  // Their client cannot notice either: its silence rule only measures silence
  // while a subscribe is outstanding, and theirs were answered before the bus
  // died — so on a cluster (docs/08 §2.1) a phone parked on this worker sat on
  // `connected` with a frozen thread and no "Connecting…", which is the
  // reported defect in the topology the scaling plan mandates.
  it("refuses new subscribes and drops the sockets it is already holding", async () => {
    // Inside the grace it still serves: a Redis restart must not cost every
    // socket on the box a reconnect.
    const { client, channel } = await openThread(b);
    expect(client.closed()).toBe(false);
    let closeCode: number | undefined;
    client.ws.on("close", (code: number) => {
      closeCode = code;
    });

    // Past the grace. Only the clock moves — the sweep's timer, the sockets
    // and the DB stay real.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + 31_000);
    // /health/realtime is the probe that goes out of rotation now (app.ts);
    // /health/ready keeps serving, because everything that is not realtime
    // still works. Asserted as the PRECONDITION for what follows: the
    // gateway's own behaviour below is what actually protects the phone.
    expect((await realtimeBody(b.port)).status).toBe(503);
    expect((await readyBody(b.port)).status).toBe(200);

    // A subscribe arriving now is answered, not served: SUBSCRIBE_FAILED is
    // what makes the client retry the channel and then stall the socket.
    const list = `user:${userId}:chats`;
    client.ws.send(JSON.stringify({ type: "subscribe", channel: list }));
    const refused = await client.next((f) => f.channel === list && f.type === "error", 10_000);
    expect(refused.error).toBe("SUBSCRIBE_FAILED");

    // And the socket that was already subscribed is closed, so the phone
    // reconnects (showing "Connecting…") instead of staring at a dead thread.
    for (let i = 0; i < 60 && !client.closed(); i++) await sleep(250);
    vi.useRealTimers();
    expect(client.closed(), "the worker never dropped its socket").toBe(true);
    expect(closeCode).toBe(4503);
    expect(channel).toContain(chatId);
  }, 40_000);
});

describe("REDIS_URL empty (baseline, in-process bus)", () => {
  let b: Booted;

  beforeAll(async () => {
    b = await boot({ REDIS_URL: "" });
  });

  afterAll(async () => {
    await b.close();
  });

  it("identical liveness, and /health/ready reports mode=local ready=true", async () => {
    const { client, channel, snapshotMs } = await openThread(b);
    expect(snapshotMs).toBeLessThan(3_000);
    const { ids } = await sendLive(b, client, channel, 3, 0, "local");
    expect(ids).toHaveLength(3);
    const ready = await readyBody(b.port);
    expect(ready.status).toBe(200);
    // toEqual, not toMatchObject: the exact shape is the contract, because
    // this body is unauthenticated and must never grow a field carrying the
    // Redis host:port or a raw ioredis message (app.ts).
    expect(ready.body).toEqual({
      ok: true,
      db: true,
      degraded: false,
      realtime: true,
      bus: { mode: "local", ready: true, droppedPublishes: 0 },
    });
    expect(b.bus.busHealth()).toMatchObject({ lastError: null, lastErrorAt: null });
    client.ws.close();
  });
});
