import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { createOrGetChat } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { parseBigIntId } from "../src/lib/ids.js";
import { applyInteractionBatch } from "../src/posts/service.js";
import { setStoreAdmin } from "../src/stores/service.js";
import { authHeader, createStore, createUserWithToken, type App } from "./helpers.js";

describe("security audit hardening", () => {
  let app: App;
  const userIds: string[] = [];
  const storeIds: string[] = [];

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  // A store admin could read ANY user's phone number, including customers who
  // had never contacted their store. Store leaderboards are readable by every
  // authenticated user and expose raw userIds, so this was directly harvestable:
  // walk a rival store's leaderboard, resolve the list to phone numbers. Phone
  // is the login identity here, which is what makes it worth protecting.
  describe("GET /users/:id phone exposure", () => {
    it("hides the phone from a store admin with no chat with that user", async () => {
      const admin = await createUserWithToken("user");
      const stranger = await createUserWithToken("user");
      userIds.push(admin.userId, stranger.userId);
      const store = await createStore("Phone Guard Co", admin.userId);
      storeIds.push(store.id);
      await setStoreAdmin(store.id, admin.userId, true);

      const { refreshedToken } = await import("./helpers.js");
      const res = await app.inject({
        method: "GET",
        url: `/api/v1/users/${stranger.userId}`,
        headers: authHeader(await refreshedToken(admin.userId)),
      });
      expect(res.statusCode).toBe(200);
      expect(res.json().user.phone).toBeUndefined();
    });

    it("shows the phone to an admin of a store that user actually chatted with", async () => {
      const admin = await createUserWithToken("user");
      const customer = await createUserWithToken("user");
      userIds.push(admin.userId, customer.userId);
      const store = await createStore("Phone Guard Co 2", admin.userId);
      storeIds.push(store.id);
      await setStoreAdmin(store.id, admin.userId, true);
      await createOrGetChat(customer.userId, store.id);

      // Re-mint so the token carries the freshly-granted store-admin claims.
      const { refreshedToken } = await import("./helpers.js");
      const res = await app.inject({
        method: "GET",
        url: `/api/v1/users/${customer.userId}`,
        headers: authHeader(await refreshedToken(admin.userId)),
      });
      expect(res.statusCode).toBe(200);
      expect(res.json().user.phone).toBeTruthy();
    });

    it("hides the phone from a plain user", async () => {
      const a = await createUserWithToken("user");
      const b = await createUserWithToken("user");
      userIds.push(a.userId, b.userId);

      const res = await app.inject({
        method: "GET",
        url: `/api/v1/users/${b.userId}`,
        headers: authHeader(a.token),
      });
      expect(res.json().user.phone).toBeUndefined();
    });

    it("always shows a user their own phone", async () => {
      const me = await createUserWithToken("user");
      userIds.push(me.userId);

      const res = await app.inject({
        method: "GET",
        url: `/api/v1/users/${me.userId}`,
        headers: authHeader(me.token),
      });
      expect(res.json().user.phone).toBeTruthy();
    });
  });

  // These returned 500 INTERNAL (an unhandled BigInt() throw) where the honest
  // answer is "that isn't a valid id".
  describe("malformed numeric ids answer 4xx, never 500", () => {
    it("rejects a non-numeric notification id", async () => {
      const user = await createUserWithToken("user");
      userIds.push(user.userId);
      const res = await app.inject({
        method: "POST",
        url: "/api/v1/notifications/abc/read",
        headers: authHeader(user.token),
      });
      expect(res.statusCode).toBe(400);
    });

    it("treats a malformed notification cursor as the first page", async () => {
      const user = await createUserWithToken("user");
      userIds.push(user.userId);
      const res = await app.inject({
        method: "GET",
        url: "/api/v1/notifications?before=abc",
        headers: authHeader(user.token),
      });
      expect(res.statusCode).toBe(200);
    });

    it("rejects a non-numeric quick-reply id", async () => {
      const admin = await createUserWithToken("superadmin");
      userIds.push(admin.userId);
      const res = await app.inject({
        method: "DELETE",
        url: "/api/v1/quick-replies/abc",
        headers: authHeader(admin.token),
      });
      expect(res.statusCode).toBe(400);
    });

    it("parseBigIntId refuses everything BigInt() would silently coerce", () => {
      expect(parseBigIntId("12")).toBe(12n);
      for (const bad of ["abc", "", " 12 ", "-1", "0x10", "1e3", "1.5", "٣", "12abc"]) {
        expect(parseBigIntId(bad), `should reject ${JSON.stringify(bad)}`).toBeUndefined();
      }
    });
  });

  // interaction_buffer.dart stores at most one row per (post, kind) per window,
  // so an honest client sends 0 or 1 per field. The old cap of 100000 across
  // 1000 items allowed 100,000,000 fabricated views in a single request.
  describe("interaction counters cannot be inflated", () => {
    it("rejects a per-field count above what a real client can produce", async () => {
      const admin = await createUserWithToken("user");
      userIds.push(admin.userId);
      const store = await createStore("Inflate Co", admin.userId);
      storeIds.push(store.id);
      const post = await prisma.post.create({
        data: { storeId: store.id, type: "image", caption: "", thumbnailUrl: "" },
      });

      const res = await app.inject({
        method: "POST",
        url: "/api/v1/posts/interactions",
        headers: authHeader(admin.token),
        payload: { items: [{ postId: post.id, views: 100000 }] },
      });
      expect(res.statusCode).toBe(400);

      const after = await prisma.post.findUnique({ where: { id: post.id } });
      expect(after?.viewsCount).toBe(0);
    });

    it("collapses the same postId repeated within one batch", async () => {
      const admin = await createUserWithToken("user");
      userIds.push(admin.userId);
      const store = await createStore("Inflate Co 2", admin.userId);
      storeIds.push(store.id);
      const post = await prisma.post.create({
        data: { storeId: store.id, type: "image", caption: "", thumbnailUrl: "" },
      });

      // Each entry is individually legal; only the repetition is the attack.
      await applyInteractionBatch(
        Array.from({ length: 50 }, () => ({ postId: post.id, views: 1 }))
      );

      const after = await prisma.post.findUnique({ where: { id: post.id } });
      expect(after?.viewsCount).toBe(1);
    });
  });
});
