import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { AccountDeletedError } from "../src/auth/claims.js";
import { clearRevocations } from "../src/auth/revocation.js";
import { createOrGetChat, sendMessage } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { acceptOrder } from "../src/orders/service.js";
import { setStoreAdmin } from "../src/stores/service.js";
import { authHeader, createStore, createUserWithToken, refreshedToken, type App } from "./helpers.js";

// Account deletion anonymizes in place rather than removing the row: a store's
// sales history is the store's data, not the customer's, and orders.userId is a
// RESTRICT FK. These tests pin down both halves of that contract — everything
// personal is really gone, and everything the store legitimately keeps survives.
describe("DELETE /users/me", () => {
  let app: App;
  const storeIds: string[] = [];
  const userIds: string[] = [];

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    clearRevocations();
  });

  it("scrubs personal data, keeps the order, and drops the leaderboard entry", async () => {
    const admin = await createUserWithToken("admin");
    const customer = await createUserWithToken();
    userIds.push(admin.userId, customer.userId);
    const store = await createStore("Deletion Co", admin.userId);
    storeIds.push(store.id);

    const chat = await createOrGetChat(customer.userId, store.id);
    await sendMessage(chat, "user", customer.userId, { text: "is this in stock?" });
    await acceptOrder(chat, admin.userId, 4);
    await prisma.userNotification.create({
      data: { userId: customer.userId, title: "hi", body: "there" },
    });

    const before = await prisma.user.findUniqueOrThrow({ where: { id: customer.userId } });
    expect(before.deletedAt).toBeNull();

    const res = await app.inject({
      method: "DELETE",
      url: "/api/v1/users/me",
      headers: authHeader(customer.token),
    });
    expect(res.statusCode).toBe(200);

    // The row survives so the order's FK stays valid, but is fully scrubbed.
    const after = await prisma.user.findUniqueOrThrow({ where: { id: customer.userId } });
    expect(after.deletedAt).not.toBeNull();
    expect(after.name).toBe("");
    expect(after.avatarUrl).toBe("");
    expect(after.phone).not.toBe(before.phone);
    expect(after.phone).toMatch(/^del_[0-9a-f]{12}$/);
    expect(after.claimsVersion).toBe(before.claimsVersion + 1);

    // Personal data is really gone.
    expect(await prisma.chat.count({ where: { userId: customer.userId } })).toBe(0);
    expect(await prisma.message.count({ where: { senderId: customer.userId } })).toBe(0);
    expect(await prisma.userNotification.count({ where: { userId: customer.userId } })).toBe(0);
    expect(await prisma.session.count({ where: { userId: customer.userId } })).toBe(0);
    expect(await prisma.userFcmToken.count({ where: { userId: customer.userId } })).toBe(0);
    // Removed from the PUBLIC leaderboard surface...
    expect(await prisma.storeLeaderboard.count({ where: { userId: customer.userId } })).toBe(0);

    // ...but the store keeps its sale, with the denormalized phone scrubbed too
    // (otherwise deletion would leak the very field it removes).
    const orders = await prisma.order.findMany({ where: { userId: customer.userId } });
    expect(orders).toHaveLength(1);
    expect(orders[0]!.itemQuantity).toBe(4);
    expect(orders[0]!.userPhone).toBe(after.phone);
    expect(orders[0]!.userPhone).not.toBe(before.phone);
  });

  it("frees the real phone number for a genuine fresh signup", async () => {
    const customer = await createUserWithToken();
    userIds.push(customer.userId);
    const original = await prisma.user.findUniqueOrThrow({ where: { id: customer.userId } });

    const res = await app.inject({
      method: "DELETE",
      url: "/api/v1/users/me",
      headers: authHeader(customer.token),
    });
    expect(res.statusCode).toBe(200);

    // A brand-new account, not a resurrection of the tombstone.
    const { findOrCreateUserByPhone } = await import("../src/auth/users.js");
    const fresh = await findOrCreateUserByPhone(original.phone);
    userIds.push(fresh.id);
    expect(fresh.id).not.toBe(customer.userId);
    expect(fresh.deletedAt).toBeNull();
  });

  it("rejects the deleted user's still-unexpired access token immediately", async () => {
    const customer = await createUserWithToken();
    userIds.push(customer.userId);

    const ok = await app.inject({
      method: "GET",
      url: "/api/v1/users/me",
      headers: authHeader(customer.token),
    });
    expect(ok.statusCode).toBe(200);

    await app.inject({
      method: "DELETE",
      url: "/api/v1/users/me",
      headers: authHeader(customer.token),
    });

    // Same token, same TTL — a stateless JWT would otherwise keep working long
    // enough to re-create the data deletion just removed.
    const after = await app.inject({
      method: "GET",
      url: "/api/v1/users/me",
      headers: authHeader(customer.token),
    });
    expect(after.statusCode).toBe(401);
  });

  it("refuses to delete a store admin's account", async () => {
    const owner = await createUserWithToken();
    userIds.push(owner.userId);
    const store = await createStore("Owned Store", owner.userId);
    storeIds.push(store.id);
    await setStoreAdmin(store.id, owner.userId, true);

    const res = await app.inject({
      method: "DELETE",
      url: "/api/v1/users/me",
      headers: authHeader(await refreshedToken(owner.userId)),
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error).toBe("STORE_OWNER_CANNOT_DELETE");

    const still = await prisma.user.findUniqueOrThrow({ where: { id: owner.userId } });
    expect(still.deletedAt).toBeNull();
  });

  // The in-memory revocation set is per-process and clears on restart, so it
  // cannot be the only thing standing between a tombstone and a live session.
  // clearRevocations() below simulates that restart: the durable check in
  // auth/claims.ts must still refuse to mint or honour claims for the tombstone.
  it("stays unauthenticatable after the revocation set is lost (process restart)", async () => {
    const customer = await createUserWithToken();
    userIds.push(customer.userId);
    const token = customer.token;

    expect(
      (await app.inject({ method: "DELETE", url: "/api/v1/users/me", headers: authHeader(token) }))
        .statusCode
    ).toBe(200);

    clearRevocations();

    // No fresh token can be minted for a tombstone...
    await expect(refreshedToken(customer.userId)).rejects.toThrow(AccountDeletedError);

    // ...and the pre-deletion token is refused on the requireFreshAuth path
    // even with nothing left in the revocation set.
    const replayed = await app.inject({
      method: "DELETE",
      url: "/api/v1/users/me",
      headers: authHeader(token),
    });
    expect(replayed.statusCode).toBe(401);
    expect(replayed.json().error).toBe("ACCOUNT_DELETED");
  });
});
