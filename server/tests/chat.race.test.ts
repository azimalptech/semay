import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { createOrGetChat, sendMessage } from "../src/chats/service.js";

// The Firestore-era bug this replaces: createOrGetChat wrote the chat doc
// asynchronously, and a message send that raced ahead of the local
// !hasPendingWrites echo could fail to find it. MySQL's synchronous upsert on
// a deterministic PK (${userId}_${storeId}) removes the async window
// entirely — this proves "create chat, immediately send" is safe even under
// concurrency, not just in the single-caller happy path already covered by
// the manual curl testing in docs/07_MIGRATION.md.
describe("chat create-then-send race", () => {
  let userId: string;
  let storeId: string;

  beforeAll(async () => {
    const phone = `+9938${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const user = await prisma.user.create({ data: { phone } });
    userId = user.id;
    const store = await prisma.store.create({ data: { name: "Race Test Store", createdById: userId } });
    storeId = store.id;
  });

  afterAll(async () => {
    await prisma.store.delete({ where: { id: storeId } }); // cascades chat/messages
    await prisma.user.delete({ where: { id: userId } });
  });

  it("never fails and never creates more than one chat row under concurrent create+send", async () => {
    const CONCURRENCY = 20;

    const results = await Promise.allSettled(
      Array.from({ length: CONCURRENCY }, async (_v, i) => {
        const chat = await createOrGetChat(userId, storeId);
        return sendMessage(chat, "user", userId, { text: `race message ${i}` });
      })
    );

    const rejected = results.filter((r) => r.status === "rejected");
    expect(rejected).toEqual([]);

    const chatCount = await prisma.chat.count({ where: { userId, storeId } });
    expect(chatCount).toBe(1);

    const messageCount = await prisma.message.count({ where: { chat: { userId, storeId } } });
    expect(messageCount).toBe(CONCURRENCY);
  });

  it("createOrGetChat is idempotent — repeated calls return the same row", async () => {
    const [a, b, c] = await Promise.all([
      createOrGetChat(userId, storeId),
      createOrGetChat(userId, storeId),
      createOrGetChat(userId, storeId),
    ]);
    expect(a.id).toBe(b.id);
    expect(b.id).toBe(c.id);
  });
});
