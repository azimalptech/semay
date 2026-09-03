// End-to-end smoke test against a REAL booted server — the check CLAUDE.md
// rule 9 asks for ("verify by booting, not just by inject()"). Boots
// src/index.ts with the local .env on SMOKE_PORT (default 18080), then drives
// it exactly the way the phone does: demo-account login → REST → WebSocket
// subscribe/snapshot → app-level ping/pong → a message round-trip observed
// over the socket → receipts. One PASS/FAIL line per step; exits non-zero on
// any failure. Never prints tokens.
//
//   npm run smoke
//
// Needs the demo account enabled in .env (OTP_TEST_PHONE / OTP_TEST_CODE, see
// docs/09_DEPLOYMENT.md) — that is the only way to log in without an SMS. The
// chat round-trip sends one message from the demo account to the first store
// in the database, so run this against dev/staging data, not production.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import WebSocket from "ws";

const PORT = Number(process.env.SMOKE_PORT || 18080);
const BASE = `http://127.0.0.1:${PORT}`;
const PHONE = process.env.OTP_TEST_PHONE || readEnv("OTP_TEST_PHONE");
const CODE = process.env.OTP_TEST_CODE || readEnv("OTP_TEST_CODE");

function readEnv(key) {
  try {
    const text = readFileSync(".env", "utf8");
    const m = text.match(new RegExp(`^${key}="?([^"\\r\\n]*)`, "m"));
    return m ? m[1] : "";
  } catch {
    return "";
  }
}

if (!PHONE || !CODE) {
  console.error("OTP_TEST_PHONE / OTP_TEST_CODE are not set — the smoke test logs in as the demo account.");
  process.exit(2);
}

const child = spawn("npx", ["tsx", "--env-file=.env", "src/index.ts"], {
  cwd: process.cwd(),
  env: { ...process.env, PORT: String(PORT) },
  shell: true,
  stdio: ["ignore", "pipe", "pipe"],
});
let bootLog = "";
child.stdout.on("data", (d) => (bootLog += d));
child.stderr.on("data", (d) => (bootLog += d));

const results = [];
function step(name, ok, detail = "") {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? " — " + detail : ""}`);
}

async function json(method, path, body, token) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = null;
  try {
    data = await res.json();
  } catch {
    /* non-JSON body */
  }
  return { status: res.status, data };
}

function wsClient(token) {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/api/v1/ws?token=${token}`);
  const frames = [];
  const waiters = [];
  ws.on("message", (raw) => {
    const f = JSON.parse(raw.toString());
    frames.push(f);
    const i = waiters.findIndex((w) => w.pred(f));
    if (i !== -1) waiters.splice(i, 1)[0].resolve(f);
  });
  const next = (pred, ms = 5000) => {
    const hit = frames.find(pred);
    if (hit) {
      frames.splice(frames.indexOf(hit), 1);
      return Promise.resolve(hit);
    }
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timeout waiting for frame")), ms);
      waiters.push({
        pred,
        resolve: (f) => {
          clearTimeout(t);
          frames.splice(frames.indexOf(f), 1);
          resolve(f);
        },
      });
    });
  };
  const open = new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  return { ws, next, open };
}

try {
  // 1. boot
  let healthy = false;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`${BASE}/health`);
      if (r.ok) {
        healthy = true;
        break;
      }
    } catch {
      /* not up yet */
    }
    if (child.exitCode !== null) break;
    await sleep(500);
  }
  step("server boots and /health answers", healthy, healthy ? "" : bootLog.slice(-800));
  if (!healthy) throw new Error("boot failed");
  const ready = await fetch(`${BASE}/health/ready`);
  step("/health/ready (DB reachable)", ready.status === 200, `status ${ready.status}`);
  // Informational only: the logger flushes through a worker thread, so these
  // lines may not have reached our pipe yet — never a failure by themselves.
  await sleep(1000);
  step("boot log: realtime mode", true, (bootLog.match(/realtime:[^\n"]*/) || ["(not captured)"])[0].trim());
  step("boot log: FCM state", true, (bootLog.match(/FCM push is [^\n"]*/) || ["no 'FCM push is DISABLED' warning"])[0].trim());

  // 2. demo-account login (no SMS, fixed code)
  const send = await json("POST", "/api/v1/auth/otp/send", { phone: PHONE });
  step("demo phone: /auth/otp/send accepted", send.status < 300, `status ${send.status}`);
  const verify = await json("POST", "/api/v1/auth/otp/verify", { phone: PHONE, code: CODE });
  const token = verify.data?.accessToken;
  step(
    "demo phone: /auth/otp/verify with the fixed code issues tokens",
    verify.status === 200 && typeof token === "string" && typeof verify.data?.refreshToken === "string",
    `status ${verify.status}`
  );
  const wrong = await json("POST", "/api/v1/auth/otp/verify", { phone: PHONE, code: "000000" });
  step("demo phone: wrong code is rejected", wrong.status === 401 || wrong.status === 400, `status ${wrong.status} ${wrong.data?.error ?? ""}`);
  if (!token) throw new Error("no token");

  const me = await json("GET", "/api/v1/users/me", undefined, token);
  step(
    "demo account exists with role=user",
    me.status === 200 && me.data?.user?.role === "user",
    `name="${me.data?.user?.name}" role=${me.data?.user?.role}`
  );
  const uid = me.data?.user?.id;

  // 3. realtime: ping → pong, subscribe → snapshot
  const c = wsClient(token);
  await c.open;
  c.ws.send(JSON.stringify({ type: "ping" }));
  const pong = await c.next((f) => f.type === "pong");
  step("ws: app-level ping answered with pong", !!pong);
  const listChannel = `user:${uid}:chats`;
  c.ws.send(JSON.stringify({ type: "subscribe", channel: listChannel }));
  const snap = await c.next((f) => f.channel === listChannel && f.type === "snapshot");
  step("ws: subscribe user chat list → snapshot", Array.isArray(snap.data), `${Array.isArray(snap.data) ? snap.data.length : "?"} chats`);

  // 4. a chat round-trip: create/get a chat with the first store, send, watch the socket
  const stores = await json("GET", "/api/v1/stores", undefined, token);
  const store = stores.data?.stores?.[0];
  if (store) {
    const chat = await json("POST", "/api/v1/chats", { storeId: store.id }, token);
    const chatId = chat.data?.chat?.id;
    step("chat: create-or-get with a store", chat.status === 201 && !!chatId, `store="${store.name}"`);
    const msgChannel = `chat:${chatId}:messages`;
    c.ws.send(JSON.stringify({ type: "subscribe", channel: msgChannel }));
    const msnap = await c.next((f) => f.channel === msgChannel && f.type === "snapshot");
    step("chat: subscribe messages → snapshot", Array.isArray(msnap.data));
    const key = `smoke-${Math.floor(Math.random() * 1e9)}`;
    const sent = await json("POST", `/api/v1/chats/${chatId}/messages`, { text: "smoke test message", clientKey: key }, token);
    step("chat: POST message returns the created row", sent.status === 201 && sent.data?.message?.clientKey === key);
    const echo = await c.next((f) => f.channel === msgChannel && f.type === "upsert" && f.data?.clientKey === key);
    step("chat: the message echoes over the socket as an upsert", !!echo);
    const listUpsert = await c.next((f) => f.channel === listChannel && f.type === "upsert" && f.data?.id === chatId);
    step(
      "chat: the chat list receives the updated chat (unreadByAdmin incremented)",
      listUpsert.data?.unreadByAdmin >= 1,
      `unreadByAdmin=${listUpsert.data?.unreadByAdmin}`
    );
    // A receipt from our own side has nothing to stamp — accepted, publishes nothing.
    const rec = await json("POST", `/api/v1/chats/${chatId}/receipts`, { status: "delivered" }, token);
    step("chat: redundant receipt is accepted", rec.status === 200);
    await sleep(300);
    const stray = await c.next((f) => f.channel === msgChannel && f.type === "receipts", 10).then(
      () => true,
      () => false
    );
    step("chat: no stray receipts frame after a no-op receipt", !stray);
  } else {
    step("chat round-trip", false, "no stores in the database — skipped");
  }

  // 5. a bad token is closed with 4401 (what the app's reconnect logic keys on)
  const bad = new WebSocket(`ws://127.0.0.1:${PORT}/api/v1/ws?token=nope`);
  const code = await new Promise((resolve) => bad.on("close", (cd) => resolve(cd)));
  step("ws: bad token closed with 4401", code === 4401, `code ${code}`);

  c.ws.close();
} catch (e) {
  step("smoke run", false, String(e?.message || e));
} finally {
  if (process.platform === "win32") {
    spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { shell: true, stdio: "ignore" });
  } else {
    child.kill("SIGTERM");
  }
  await sleep(500);
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} steps passed`);
  process.exit(failed.length ? 1 : 0);
}
