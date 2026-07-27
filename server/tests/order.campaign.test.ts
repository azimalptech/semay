import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { createOrGetChat } from "../src/chats/service.js";
import { acceptOrder } from "../src/orders/service.js";

// A store's campaign end date freezes its leaderboard: orders accepted after it
// still record as sales but no longer move the standings. This proves the
// [campaignStartAt, campaignEndAt] window is enforced at accept-time — after
// the end, quantity stops climbing; with no window set, it counts as before.
describe("acceptOrder campaign window", () => {
  let adminId: string;
  let userId: string;
  let endedStore: string;
  let openStore: string;

  beforeAll(async () => {
    const admin = await prisma.user.create({
      data: { phone: `+9939${Math.floor(1_000_000 + Math.random() * 8_999_999)}`, role: "admin" },
    });
    const customer = await prisma.user.create({
      data: { phone: `+9939${Math.floor(1_000_000 + Math.random() * 8_999_999)}`, name: "Buyer" },
    });
    adminId = admin.id;
    userId = customer.id;

    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const ended = await prisma.store.create({
      data: {
        name: "Ended Campaign",
        createdById: adminId,
        campaignStartAt: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000),
        campaignEndAt: yesterday,
      },
    });
    const open = await prisma.store.create({
      data: { name: "No Campaign", createdById: adminId }, // both NULL = always counts
    });
    endedStore = ended.id;
    openStore = open.id;
  });

  afterAll(async () => {
    await prisma.store.deleteMany({ where: { id: { in: [endedStore, openStore] } } });
    await prisma.user.deleteMany({ where: { id: { in: [adminId, userId] } } });
  });

  it("does NOT move the leaderboard for an order after the campaign ended (but records the sale)", async () => {
    const chat = await createOrGetChat(userId, endedStore);
    await acceptOrder(chat, adminId, 3);

    const orders = await prisma.order.count({ where: { storeId: endedStore } });
    expect(orders).toBe(1); // the sale is still recorded
    const entry = await prisma.storeLeaderboard.findUnique({
      where: { storeId_userId: { storeId: endedStore, userId } },
    });
    expect(entry).toBeNull(); // but the standings did not move
  });

  it("DOES move the leaderboard when no campaign window is set", async () => {
    const chat = await createOrGetChat(userId, openStore);
    await acceptOrder(chat, adminId, 5);

    const entry = await prisma.storeLeaderboard.findUnique({
      where: { storeId_userId: { storeId: openStore, userId } },
    });
    expect(entry?.quantity).toBe(5);
  });
});
