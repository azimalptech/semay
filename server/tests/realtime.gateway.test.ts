import type { AddressInfo } from "node:net";

import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import WebSocket from "ws";

import { buildApp } from "../src/app.js";
import {
  FRAME_BUCKET_CAPACITY,
  FRAME_FLOOD_CLOSE,
  FRAME_REFILL_PER_SEC,
  MAX_CHANNELS_PER_SOCKET,
} from "../src/realtime/gateway.js";
import { createOrGetChat, hideChat, markReceipts, sendMessage } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import * as channels from "../src/realtime/channels.js";
import {
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  refreshedToken,
} from "./helpers.js";

// The gateway is the one surface app.inject() cannot reach — it needs a real
// listener and a real socket (CLAUDE.md rule 9). These are the chat-liveness
// contracts the mobile client's realtime_client.dart depends on: the
// application-level ping/pong it uses to test a socket it kept through a
// background suspension, the snapshot-then-diff sequence, the compact
// `receipts` roll-up that replaced re-snapshotting 200 messages per receipt,
// and the removal of the server-side activeChatId suppression that could
// leave a chat permanently silent.

interface Frame {
  channel?: string;
  type: string;
  data?: unknown;
  error?: string;
}

/** A connected client whose frames can be awaited by predicate — every frame
 * is queued so a frame that arrives before the test asks for it is not lost. */
async function connect(port: number, token: string): Promise<{
  ws: WebSocket;
  next: (pred: (f: Frame) => boolean) => Promise<Frame>;
  frames: Frame[];
}> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/api/v1/ws?token=${token}`);
  const frames: Frame[] = [];
  const waiters: { pred: (f: Frame) => boolean; resolve: (f: Frame) => void }[] = [];
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
  const next = (pred: (f: Frame) => boolean): Promise<Frame> => {
    const already = frames.find(pred);
    if (already) {
      frames.splice(frames.indexOf(already), 1);
      return Promise.resolve(already);
    }
    return new Promise<Frame>((resolve, reject) => {
      // Generous: subscribe → snapshot is several MySQL queries plus a Redis
      // SUBSCRIBE round trip on a shared dev database.
      const timer = setTimeout(() => reject(new Error("timed out waiting for frame")), 10000);
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
  return { ws, next, frames };
}

describe("realtime gateway over a real socket", () => {
  let app: FastifyInstance;
  let port: number;
  let userId: string;
  let userToken: string;
  let adminId: string;
  let storeId: string;
  let chatId: string;

  beforeAll(async () => {
    app = await buildApp();
    await app.listen({ port: 0, host: "127.0.0.1" });
    port = (app.server.address() as AddressInfo).port;

    ({ userId, token: userToken } = await createUserWithToken("user"));
    ({ userId: adminId } = await createUserWithToken("admin"));
    const store = await createStore("Gateway Test Store", adminId);
    storeId = store.id;
    await prisma.storeAdmin.create({ data: { userId: adminId, storeId } });
    chatId = (await createOrGetChat(userId, storeId)).id;
  });

  afterAll(async () => {
    await app.close();
    await cleanupStores([storeId]);
    await cleanupUsers([userId, adminId]);
  });

  it("closes an unauthenticated socket with 4401", async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/v1/ws?token=not-a-token`);
    const code = await new Promise<number>((resolve) => ws.on("close", (c) => resolve(c)));
    expect(code).toBe(4401);
  });

  it("answers an application-level ping with a pong", async () => {
    const { ws, next } = await connect(port, userToken);
    ws.send(JSON.stringify({ type: "ping" }));
    const pong = await next((f) => f.type === "pong");
    expect(pong.channel).toBeUndefined();
    ws.close();
  });

  it("survives hostile frames — `null`, scalars, arrays, garbage — and keeps answering", async () => {
    // `null` parses as JSON and the first property access on it threw
    // synchronously inside ws's receiver: an uncaught exception, i.e. any
    // authenticated client could stop the whole process with four bytes.
    const { ws, next } = await connect(port, userToken);
    for (const frame of ["null", "1", '"x"', "[]", "true", "{}", "not json", '{"type":"subscribe"}']) {
      ws.send(frame);
    }
    ws.send(JSON.stringify({ type: "ping" }));
    const pong = await next((f) => f.type === "pong");
    expect(pong.type).toBe("pong");
    // And the listener itself is still alive for other clients.
    const health = await fetch(`http://127.0.0.1:${port}/health`);
    expect(health.status).toBe(200);
    ws.close();
  });

  it("a delivered receipt rolls up as `receipts` bounded by the newest stamped id", async () => {
    const { ws, next } = await connect(port, userToken);
    const channel = `chat:${chatId}:messages`;
    ws.send(JSON.stringify({ type: "subscribe", channel }));
    await next((f) => f.channel === channel && f.type === "snapshot");

    const chat = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    const sent = await sendMessage(chat, "admin", adminId, { text: "delivered?" });
    await next((f) => f.channel === channel && f.type === "upsert");

    await markReceipts(chat, "user", "delivered");
    const receipts = await next((f) => f.channel === channel && f.type === "receipts");
    const data = receipts.data as { status: string; senderRole: string; upToMessageId: string | null };
    expect(data.status).toBe("delivered");
    expect(data.senderRole).toBe("admin");
    expect(data.upToMessageId).toBe(sent.id.toString());

    const row = await prisma.message.findUniqueOrThrow({ where: { id: sent.id } });
    expect(row.deliveredAt).not.toBeNull();
    expect(row.readAt).toBeNull();

    // 'delivered' must not clear the unread badge — only 'read' does.
    const after = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    expect(after.unreadByUser).toBeGreaterThan(0);

    await markReceipts(chat, "user", "read"); // leave the fixture read for the next test
    await next((f) => f.channel === channel && f.type === "receipts");
    ws.close();
  });

  it("subscribe → snapshot, then a live upsert, then a compact receipts event (never a re-snapshot)", async () => {
    const { ws, next, frames } = await connect(port, userToken);
    const channel = `chat:${chatId}:messages`;
    ws.send(JSON.stringify({ type: "subscribe", channel }));

    const snapshot = await next((f) => f.channel === channel && f.type === "snapshot");
    expect(Array.isArray(snapshot.data)).toBe(true);

    const chat = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    const sent = await sendMessage(chat, "admin", adminId, { text: "hello from the store" });
    const upsert = await next((f) => f.channel === channel && f.type === "upsert");
    expect((upsert.data as { id: string; text: string }).text).toBe("hello from the store");
    expect(String((upsert.data as { id: string }).id)).toBe(sent.id.toString());

    await markReceipts(chat, "user", "read");
    const receipts = await next((f) => f.channel === channel && f.type === "receipts");
    const data = receipts.data as {
      senderRole: string;
      status: string;
      at: string;
      upToMessageId: string | null;
    };
    expect(data.senderRole).toBe("admin");
    expect(data.status).toBe("read");
    expect(Date.parse(data.at)).not.toBeNaN();
    expect(data.upToMessageId).toBe(sent.id.toString());

    // The stamp the client applies from the event is the one the DB holds.
    const row = await prisma.message.findUniqueOrThrow({ where: { id: sent.id } });
    expect(row.readAt?.toISOString()).toBe(data.at);
    expect(row.deliveredAt?.toISOString()).toBe(data.at);

    // A second, redundant receipt changes nothing and must publish nothing.
    await markReceipts(chat, "user", "read");
    await new Promise((r) => setTimeout(r, 200));
    expect(frames.filter((f) => f.channel === channel && f.type === "snapshot")).toEqual([]);
    expect(frames.filter((f) => f.channel === channel && f.type === "receipts")).toEqual([]);

    ws.close();
  });

  it("a stranger subscribing to the chat is refused", async () => {
    const stranger = await createUserWithToken("user");
    try {
      const { ws, next } = await connect(port, stranger.token);
      const channel = `chat:${chatId}:messages`;
      ws.send(JSON.stringify({ type: "subscribe", channel }));
      const err = await next((f) => f.channel === channel && f.type === "error");
      expect(err.error).toBe("FORBIDDEN");
      ws.close();
    } finally {
      await cleanupUsers([stranger.userId]);
    }
  });

  it("still counts unread (and clears it on read) while users.activeChatId points at the chat", async () => {
    // The old suppression keyed on this flag, and a killed app left it stuck —
    // that chat then never badged or notified again. Suppression now lives on
    // the device, so the server must count regardless.
    await prisma.user.update({ where: { id: userId }, data: { activeChatId: chatId } });
    try {
      const before = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
      await sendMessage(before, "admin", adminId, { text: "are you there?" });
      const after = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
      expect(after.unreadByUser).toBe(before.unreadByUser + 1);

      await markReceipts(after, "user", "read");
      const read = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
      expect(read.unreadByUser).toBe(0);
    } finally {
      await prisma.user.update({ where: { id: userId }, data: { activeChatId: null } });
    }
  });

  it("store:{id}: subscribe gets the store row, and a PATCH delivers the rename live", async () => {
    // Before this pass the channel did not exist: every store-profile open
    // sent this subscribe and was answered UNKNOWN_CHANNEL, and PATCH
    // /stores/:id published into a channel nobody could hold — so a rename
    // reached only the admin who made it (edit_store_screen invalidates its
    // own provider), and every other open profile/chat header kept the old
    // name until it was torn down.
    const { ws, next } = await connect(port, userToken);
    const channel = `store:${storeId}`;
    ws.send(JSON.stringify({ type: "subscribe", channel }));

    const snapshot = await next((f) => f.channel === channel && f.type === "snapshot");
    expect((snapshot.data as { id: string }).id).toBe(storeId);

    const renamed = `Gateway Test Store ${Date.now()}`;
    const res = await app.inject({
      method: "PATCH",
      url: `/api/v1/stores/${storeId}`,
      headers: { authorization: `Bearer ${await refreshedToken(adminId)}` },
      payload: { name: renamed },
    });
    expect(res.statusCode).toBe(200);

    const upsert = await next((f) => f.channel === channel && f.type === "upsert");
    expect((upsert.data as { name: string }).name).toBe(renamed);
    ws.close();
    await prisma.store.update({ where: { id: storeId }, data: { name: "Gateway Test Store" } });
  });

  // Last in the file on purpose: it hides the shared chat for the customer.
  it("chat-delete: the snapshot after a delete stops at that side's cutoff; the other side's does not", async () => {
    // The snapshot used to call listMessages with the chat id alone — no
    // side, no cutoff — so a customer who deleted the chat got every old
    // message back the moment the thread resubscribed.
    const chat = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    const before = await sendMessage(chat, "admin", adminId, { text: "before the delete" });
    await hideChat(chat, "user");
    const hidden = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    const after = await sendMessage(hidden, "admin", adminId, { text: "after the delete" });

    const channel = `chat:${chatId}:messages`;
    const user = await connect(port, userToken);
    user.ws.send(JSON.stringify({ type: "subscribe", channel }));
    const userSnap = await user.next((f) => f.channel === channel && f.type === "snapshot");
    expect((userSnap.data as { id: string }[]).map((m) => m.id)).toEqual([after.id.toString()]);
    user.ws.close();

    // The fixture discarded the admin's token; any valid token for adminId
    // will do — the gateway derives role/storeIds from the DB, not the token.
    const admin = await connect(port, await refreshedToken(adminId));
    admin.ws.send(JSON.stringify({ type: "subscribe", channel }));
    const adminSnap = await admin.next((f) => f.channel === channel && f.type === "snapshot");
    const adminIds = (adminSnap.data as { id: string }[]).map((m) => m.id);
    expect(adminIds).toContain(before.id.toString());
    expect(adminIds).toContain(after.id.toString());
    admin.ws.close();
  });
});

describe("a subscribe that fails is reported, never silent", () => {
  let app: FastifyInstance;
  let port: number;
  let userId: string;
  let userToken: string;

  beforeAll(async () => {
    app = await buildApp();
    await app.listen({ port: 0, host: "127.0.0.1" });
    port = (app.server.address() as AddressInfo).port;
    ({ userId, token: userToken } = await createUserWithToken("user"));
  });

  afterAll(async () => {
    await app.close();
    await cleanupUsers([userId]);
  });

  it("a snapshot that throws yields SUBSCRIBE_FAILED and rolls the attempt back so a retry works", async () => {
    // Before: the catch deleted the placeholder and sent nothing, so the
    // client sat on a subscribe with no snapshot and no error — forever, with
    // the socket looking healthy. The bus listener it had installed leaked
    // too. Now the client is told, and the same channel can be subscribed
    // again (the attempt is gone from the per-socket map, so it is not a
    // "already subscribed" no-op).
    const real = channels.findChannelHandler;
    const spy = vi.spyOn(channels, "findChannelHandler").mockImplementationOnce((name) => {
      const found = real(name);
      if (!found) return found;
      return {
        ...found,
        handler: {
          ...found.handler,
          snapshot: async () => {
            throw new Error("snapshot exploded");
          },
        },
      };
    });
    try {
      const { ws, next } = await connect(port, userToken);
      const channel = "post:no-such-post";
      ws.send(JSON.stringify({ type: "subscribe", channel }));
      const err = await next((f) => f.channel === channel && f.type === "error");
      expect(err.error).toBe("SUBSCRIBE_FAILED");

      ws.send(JSON.stringify({ type: "subscribe", channel }));
      const snapshot = await next((f) => f.channel === channel && f.type === "snapshot");
      expect(snapshot.data).toBeNull(); // a public post channel: no such row, no error
      ws.close();
    } finally {
      spy.mockRestore();
    }
  });

  it("a subscribe whose account is gone answers FORBIDDEN, not silence", async () => {
    // authContext() resolves undefined for a missing or soft-deleted user —
    // a token still inside its 15-minute TTL for an account deleted
    // mid-session. This branch used to delete the placeholder and return
    // WITHOUT sending anything, which the client's silence deadline reads as
    // "the server is not delivering": drop the socket, reconnect (the token
    // still verifies), subscribe, silence again, forever, with "Connecting…"
    // pinned on screen and a REST re-seed on every cycle. FORBIDDEN rather
    // than SUBSCRIBE_FAILED, because a missing account is final: the client
    // hands it to the consumer instead of retrying.
    const { userId: goneId, token: goneToken } = await createUserWithToken("user");
    try {
      await prisma.user.update({ where: { id: goneId }, data: { deletedAt: new Date() } });
      const { ws, next, frames } = await connect(port, goneToken);
      const channel = "post:no-such-post";
      ws.send(JSON.stringify({ type: "subscribe", channel }));
      const err = await next((f) => f.channel === channel && f.type === "error");
      expect(err.error).toBe("FORBIDDEN");
      expect(frames.filter((f) => f.type === "snapshot")).toEqual([]);
      ws.close();
    } finally {
      await prisma.user.update({ where: { id: goneId }, data: { deletedAt: null } });
      await cleanupUsers([goneId]);
    }
  }, 20_000);

  it("a superseded attempt never reports SUBSCRIBE_FAILED for a channel that is working", async () => {
    // The failure path guarded the state rollback with mine() but sent the
    // error frame unconditionally. A subscribe → unsubscribe → subscribe burst
    // on one socket (leaving and re-entering a thread, a Riverpod consumer
    // rebuilding) leaves attempt A hanging while attempt B installs its
    // listener and delivers its snapshot; A then hitting the 10 s deadline
    // told the client a working channel had failed — and the client answers
    // SUBSCRIBE_FAILED by re-subscribing and, on a second one, dropping the
    // WHOLE socket, costing every other channel on it a reconnect plus a REST
    // re-seed.
    const real = channels.findChannelHandler;
    const spy = vi.spyOn(channels, "findChannelHandler").mockImplementationOnce((name) => {
      const found = real(name);
      if (!found) return found;
      return {
        ...found,
        // Never settles: the attempt can only end at SUBSCRIBE_DEADLINE_MS.
        handler: { ...found.handler, snapshot: () => new Promise<never>(() => {}) },
      };
    });
    try {
      const { ws, next, frames } = await connect(port, userToken);
      const channel = "post:no-such-post";
      ws.send(JSON.stringify({ type: "subscribe", channel }));
      // Give A time to install its bus listener before superseding it.
      await new Promise((r) => setTimeout(r, 300));
      ws.send(JSON.stringify({ type: "unsubscribe", channel }));
      ws.send(JSON.stringify({ type: "subscribe", channel }));
      const snapshot = await next((f) => f.channel === channel && f.type === "snapshot");
      expect(snapshot.data).toBeNull();

      // Past the server's own subscribe deadline, so A has certainly given up.
      await new Promise((r) => setTimeout(r, 11_000));
      expect(frames.filter((f) => f.type === "error")).toEqual([]);
      ws.close();
    } finally {
      spy.mockRestore();
    }
  }, 30_000);
});

// A `receipts` frame whose upToMessageId is null says "I stamped nothing", and
// there is no useful thing a client can do with it. markReceipts used to
// publish it anyway, because its publish gate counted the unread counter being
// cleared as a change: a read receipt that stamped no message but zeroed a
// non-zero unread — reachable when a sendMessage commits between the message
// updateMany and the chat updateMany — emitted a null-bounded roll-up. The
// client read the null bound as "no upper bound" and stamped the whole window
// blue (chat_providers.dart _applyReceipts, now guarded on both sides).
describe("a receipts roll-up that stamped no message is not published", () => {
  let app: FastifyInstance;
  let port: number;
  let userId: string;
  let userToken: string;
  let adminId: string;
  let storeId: string;
  let chatId: string;

  beforeAll(async () => {
    app = await buildApp();
    await app.listen({ port: 0, host: "127.0.0.1" });
    port = (app.server.address() as AddressInfo).port;
    ({ userId, token: userToken } = await createUserWithToken("user"));
    ({ userId: adminId } = await createUserWithToken("admin"));
    const store = await createStore("Null Bound Store", adminId);
    storeId = store.id;
    await prisma.storeAdmin.create({ data: { userId: adminId, storeId } });
    chatId = (await createOrGetChat(userId, storeId)).id;
  });

  afterAll(async () => {
    await app.close();
    await cleanupStores([storeId]);
    await cleanupUsers([userId, adminId]);
  });

  it("clears the unread on the chat document without a null-bounded frame on the thread", async () => {
    const messages = `chat:${chatId}:messages`;
    const doc = `chat:${chatId}`;
    const { ws, next, frames } = await connect(port, userToken);
    ws.send(JSON.stringify({ type: "subscribe", channel: messages }));
    await next((f) => f.channel === messages && f.type === "snapshot");
    ws.send(JSON.stringify({ type: "subscribe", channel: doc }));
    await next((f) => f.channel === doc && f.type === "snapshot");

    // Every message already read, but the counter is not zero — exactly the
    // state the race leaves behind (the message updateMany saw no new row;
    // the chat updateMany's locking read saw the increment).
    const sent = await sendMessage(
      await prisma.chat.findUniqueOrThrow({ where: { id: chatId } }),
      "admin",
      adminId,
      { text: "read me" }
    );
    await next((f) => f.channel === messages && f.type === "upsert");
    await markReceipts(
      await prisma.chat.findUniqueOrThrow({ where: { id: chatId } }),
      "user",
      "read"
    );
    await next((f) => f.channel === messages && f.type === "receipts");
    expect(
      (await prisma.message.findUniqueOrThrow({ where: { id: sent.id } })).readAt
    ).not.toBeNull();
    await prisma.chat.update({ where: { id: chatId }, data: { unreadByUser: 1 } });
    await next((f) => f.channel === doc && f.type === "upsert").catch(() => undefined);
    frames.length = 0;

    await markReceipts(
      await prisma.chat.findUniqueOrThrow({ where: { id: chatId } }),
      "user",
      "read"
    );
    // The chat document still carries the unread change — the receipt did
    // something, it just did not stamp a message.
    const upsert = await next((f) => f.channel === doc && f.type === "upsert");
    expect((upsert.data as { unreadByUser: number }).unreadByUser).toBe(0);
    await new Promise((r) => setTimeout(r, 300));
    expect(frames.filter((f) => f.channel === messages)).toEqual([]);

    ws.close();
  }, 30_000);
});

// What ONE authenticated socket is allowed to cost this process.
//
// Neither of these was bounded before: the channel map grew without limit, and
// every frame on it was JSON.parsed synchronously inside ws's receiver and
// could carry a subscribe (an authorize plus a snapshot — 200 rows for a chat
// thread). ws's 4 KiB maxPayload (app.ts) bounds the SIZE of a frame and
// nothing else. The `store:{id}` handler added in this pass widened the
// reachable set again: like `post:{id}` it authorizes every authenticated
// user, so one account can walk the whole store table and hold a channel for
// each row. Both bounds are deliberately far above anything the app does.
describe("realtime gateway: per-socket bounds", () => {
  let app: FastifyInstance;
  let port: number;
  let userId: string;
  let userToken: string;

  const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

  /** Sends `frames` paced so the token bucket is never the thing that fails —
   * the cap test must exercise the CHANNEL ceiling, not the rate limit. */
  async function sendPaced(ws: WebSocket, frames: unknown[]): Promise<void> {
    const chunk = Math.floor(FRAME_BUCKET_CAPACITY * 0.8);
    for (let i = 0; i < frames.length; i += chunk) {
      for (const f of frames.slice(i, i + chunk)) ws.send(JSON.stringify(f));
      if (i + chunk < frames.length) {
        // Refill the chunk we just spent, plus slack.
        await sleep((chunk / FRAME_REFILL_PER_SEC) * 1_000 + 500);
      }
    }
  }

  beforeAll(async () => {
    app = await buildApp();
    await app.listen({ port: 0, host: "127.0.0.1" });
    port = (app.server.address() as AddressInfo).port;
    ({ userId, token: userToken } = await createUserWithToken("user"));
  });

  afterAll(async () => {
    await app.close();
    await cleanupUsers([userId]);
  });

  it(`serves ${MAX_CHANNELS_PER_SOCKET} channels and answers the next one CHANNEL_LIMIT`, async () => {
    const { ws, next, frames } = await connect(port, userToken);
    const channels = Array.from({ length: MAX_CHANNELS_PER_SOCKET }, (_, i) => `post:cap-${i}`);
    await sendPaced(
      ws,
      channels.map((channel) => ({ type: "subscribe", channel }))
    );
    // Every one of them served — the ceiling is a ceiling, not a throttle.
    // Polled rather than awaited on the LAST channel: the subscribes are
    // handled concurrently and their snapshots come back in whatever order
    // their queries finish, so the last one asked for is routinely not the
    // last one answered.
    const served = new Set<string | undefined>();
    const deadline = Date.now() + 30_000;
    while (served.size < MAX_CHANNELS_PER_SOCKET && Date.now() < deadline) {
      for (const f of frames) if (f.type === "snapshot") served.add(f.channel);
      if (served.size < MAX_CHANNELS_PER_SOCKET) await sleep(100);
    }
    expect(served.size).toBe(MAX_CHANNELS_PER_SOCKET);
    expect([...served].sort()).toEqual([...channels].sort());

    const overflow = "post:cap-overflow";
    ws.send(JSON.stringify({ type: "subscribe", channel: overflow }));
    const refused = await next((f) => f.channel === overflow);
    expect(refused.type).toBe("error");
    expect(refused.error).toBe("CHANNEL_LIMIT");
    // Refusing one channel must not cost the socket: the app treats
    // CHANNEL_LIMIT like FORBIDDEN (a per-channel verdict), not like
    // SUBSCRIBE_FAILED, and every other channel on this connection keeps
    // working.
    expect(ws.readyState).toBe(WebSocket.OPEN);
    ws.send(JSON.stringify({ type: "ping" }));
    expect((await next((f) => f.type === "pong")).type).toBe("pong");

    // And it bounds what is HELD, not what was ever asked for: free one and
    // the next subscribe is served again.
    ws.send(JSON.stringify({ type: "unsubscribe", channel: channels[0]! }));
    ws.send(JSON.stringify({ type: "subscribe", channel: overflow }));
    const served2 = await next((f) => f.channel === overflow);
    expect(served2.type).toBe("snapshot");
    ws.close();
  }, 120_000);

  it("closes a socket that outruns the frame budget with 4429, and leaves a normal burst alone", async () => {
    // A launch-sized salvo is well inside the bucket and must be untouched.
    const calm = await connect(port, userToken);
    for (let i = 0; i < Math.floor(FRAME_BUCKET_CAPACITY / 2); i++) {
      calm.ws.send(JSON.stringify({ type: "ping" }));
    }
    expect((await calm.next((f) => f.type === "pong")).type).toBe("pong");
    await sleep(300);
    expect(calm.ws.readyState).toBe(WebSocket.OPEN);
    calm.ws.close();

    // A flood is not.
    const flood = await connect(port, userToken);
    const closed = new Promise<number>((resolve) => flood.ws.on("close", (c) => resolve(c)));
    for (let i = 0; i < FRAME_BUCKET_CAPACITY + 20; i++) {
      flood.ws.send(JSON.stringify({ type: "ping" }));
    }
    expect(await closed).toBe(FRAME_FLOOD_CLOSE);
  }, 60_000);
});
