import type { AddressInfo } from "node:net";

import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import WebSocket from "ws";

import { buildApp } from "../src/app.js";
import { createOrGetChat, markReceipts, sendMessage } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { cleanupStores, cleanupUsers, createStore, createUserWithToken } from "./helpers.js";

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
});
