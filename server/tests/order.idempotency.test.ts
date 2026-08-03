import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createOrGetChat } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { acceptOrder } from "../src/orders/service.js";

// Accepting an order is a real sale AND increments the prize leaderboard, but
// had no dedup: if the request succeeded server-side and the response was lost
// (flaky mobile network), the admin's natural retry recorded a second sale and
// double-counted the customer's standings. The client now sends one key per
// accept-sheet session, mirroring the mechanism messages already used.
describe("accepting an order is idempotent", () => {
  let userId: string;
  let adminId: string;
  let storeId: string;

  beforeAll(async () => {
    const mkPhone = () => `+9935${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const customer = await prisma.user.create({ data: { phone: mkPhone(), name: "Customer" } });
    const admin = await prisma.user.create({ data: { phone: mkPhone(), role: "admin" } });
    userId = customer.id;
    adminId = admin.id;
    const store = await prisma.store.create({
      data: { name: "Idempotency Store", createdById: admin.id },
    });
    storeId = store.id;
  });

  afterAll(async () => {
    await prisma.order.deleteMany({ where: { storeId } });
    await prisma.store.delete({ where: { id: storeId } });
    await prisma.user.deleteMany({ where: { id: { in: [userId, adminId] } } });
  });

  it("a retry with the same key returns the original order, and does not double-count", async () => {
    const chat = await createOrGetChat(userId, storeId);
    const key = `order-key-${Date.now()}`;

    const first = await acceptOrder(chat, adminId, 3, key);
    const retry = await acceptOrder(chat, adminId, 3, key);

    expect(retry.id).toBe(first.id);

    const orders = await prisma.order.findMany({ where: { storeId, userId } });
    expect(orders).toHaveLength(1);

    // The prize leaderboard must reflect ONE sale of 3, not 6.
    const board = await prisma.storeLeaderboard.findUnique({
      where: { storeId_userId: { storeId, userId } },
    });
    expect(board?.quantity).toBe(3);

    // And the chat shows one "Order accepted" system message, not two.
    const systemMessages = await prisma.message.findMany({
      where: { chatId: chat.id, orderId: first.id },
    });
    expect(systemMessages).toHaveLength(1);
  });

  it("survives two simultaneous accepts carrying the same key", async () => {
    const chat = await createOrGetChat(userId, storeId);
    const key = `race-key-${Date.now()}`;

    // Both fly past the fast-path check together; the UNIQUE index decides.
    const [a, b] = await Promise.all([
      acceptOrder(chat, adminId, 2, key),
      acceptOrder(chat, adminId, 2, key),
    ]);

    expect(a.id).toBe(b.id);
    expect(await prisma.order.count({ where: { clientKey: key } })).toBe(1);
  });

  it("still records a genuinely separate sale under a different key", async () => {
    const chat = await createOrGetChat(userId, storeId);

    const one = await acceptOrder(chat, adminId, 1, `distinct-a-${Date.now()}`);
    const two = await acceptOrder(chat, adminId, 1, `distinct-b-${Date.now()}`);

    expect(two.id).not.toBe(one.id);
  });

  it("keeps working without a key at all (older app builds)", async () => {
    const chat = await createOrGetChat(userId, storeId);

    const a = await acceptOrder(chat, adminId, 1);
    const b = await acceptOrder(chat, adminId, 1);

    // No key means no dedup guarantee — two distinct sales, exactly the
    // behavior every build had before idempotency existed.
    expect(b.id).not.toBe(a.id);
  });
});
