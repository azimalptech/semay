import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { createOrGetChat, sendMessage } from "../src/chats/service.js";

// The offline outbox (Phase 9b) retries a send under flaky signal reusing the
// same client-generated key. This proves the server dedupes on it: a retried
// send — even a burst of concurrent retries — produces exactly one message
// row and returns the same id, so a replayed outbox can't double-send.
describe("message send idempotency (clientKey)", () => {
  let userId: string;
  let storeId: string;
  let chatId: string;

  beforeAll(async () => {
    const phone = `+9939${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const user = await prisma.user.create({ data: { phone } });
    userId = user.id;
    const store = await prisma.store.create({ data: { name: "Idem Test Store", createdById: userId } });
    storeId = store.id;
    const chat = await createOrGetChat(userId, storeId);
    chatId = chat.id;
  });

  afterAll(async () => {
    await prisma.store.delete({ where: { id: storeId } }); // cascades chat/messages
    await prisma.user.delete({ where: { id: userId } });
  });

  it("a retried send with the same clientKey returns the same message, no duplicate", async () => {
    const chat = await createOrGetChat(userId, storeId);
    const key = `retry-${Date.now()}`;

    const first = await sendMessage(chat, "user", userId, { text: "hi", clientKey: key });
    const second = await sendMessage(chat, "user", userId, { text: "hi", clientKey: key });

    expect(second.id).toBe(first.id);
    const count = await prisma.message.count({ where: { chatId, clientKey: key } });
    expect(count).toBe(1);
  });

  it("a burst of concurrent same-key sends still creates exactly one row", async () => {
    const chat = await createOrGetChat(userId, storeId);
    const key = `race-${Date.now()}`;

    const results = await Promise.all(
      Array.from({ length: 10 }, () =>
        sendMessage(chat, "user", userId, { text: "race", clientKey: key })
      )
    );

    const ids = new Set(results.map((m) => m.id.toString()));
    expect(ids.size).toBe(1);
    const count = await prisma.message.count({ where: { chatId, clientKey: key } });
    expect(count).toBe(1);
  });
});
