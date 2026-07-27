import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { setStoreAdmin } from "../src/stores/service.js";
import { prisma } from "../src/db.js";
import {
  authHeader,
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  refreshedToken,
  type App,
} from "./helpers.js";

// Per-route x per-role authorization matrix. Firestore's rules file had no
// direct equivalent in the new stack (see docs/07_MIGRATION.md); this suite is
// the replacement — every route that used to be rules-gated gets a case here
// asserting each role sees exactly the status the old rules would have given.
describe("authz matrix", () => {
  let app: App;

  let plainUserId: string;
  let plainUserToken: string;
  let adminAId: string;
  let adminAToken: string; // admin of storeA only
  let adminBId: string;
  let adminBToken: string; // admin of storeB only (wrong-store admin)
  let superadminId: string;
  let superadminToken: string;

  let storeAId: string;
  let storeBId: string;

  // Dedicated no-op target for the /admins revoke test — must NOT be
  // plainUserId/adminAId/etc: setStoreAdmin unconditionally bumps the target's
  // claims_version even on a no-op revoke, which would stale their token for
  // every later case in this file.
  let revokeTargetId: string;

  beforeAll(async () => {
    app = await buildApp();

    const plain = await createUserWithToken("user");
    plainUserId = plain.userId;
    plainUserToken = plain.token;

    const a = await createUserWithToken("user");
    adminAId = a.userId;
    const b = await createUserWithToken("user");
    adminBId = b.userId;

    const sa = await createUserWithToken("superadmin");
    superadminId = sa.userId;
    superadminToken = sa.token;

    const storeA = await createStore("Matrix Store A", superadminId);
    const storeB = await createStore("Matrix Store B", superadminId);
    storeAId = storeA.id;
    storeBId = storeB.id;

    await setStoreAdmin(storeAId, adminAId, true);
    await setStoreAdmin(storeBId, adminBId, true);
    adminAToken = await refreshedToken(adminAId);
    adminBToken = await refreshedToken(adminBId);

    const target = await createUserWithToken("user");
    revokeTargetId = target.userId;
  });

  afterAll(async () => {
    await cleanupStores([storeAId, storeBId]);
    await cleanupUsers([plainUserId, adminAId, adminBId, superadminId, revokeTargetId]);
    await app.close();
  });

  describe("POST /api/v1/stores (superadmin only)", () => {
    const cases: [string, () => string, number][] = [
      ["plain user", () => plainUserToken, 403],
      ["wrong-store admin", () => adminAToken, 403],
      ["superadmin", () => superadminToken, 201],
    ];
    it.each(cases)("%s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: "/api/v1/stores",
        headers: authHeader(getToken()),
        payload: { name: `Matrix Temp ${Math.random()}` },
      });
      expect(res.statusCode).toBe(expected);
      if (res.statusCode === 201) {
        await prisma.store.delete({ where: { id: res.json().store.id } });
      }
    });

    it("unauthenticated -> 401", async () => {
      const res = await app.inject({
        method: "POST",
        url: "/api/v1/stores",
        payload: { name: "no-auth" },
      });
      expect(res.statusCode).toBe(401);
    });
  });

  describe("POST /api/v1/stores/:id/admins (superadmin only)", () => {
    const cases: [string, () => string, number][] = [
      ["plain user", () => plainUserToken, 403],
      ["wrong-store admin", () => adminBToken, 403],
      ["superadmin", () => superadminToken, 200],
    ];
    it.each(cases)("%s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/stores/${storeAId}/admins`,
        headers: authHeader(getToken()),
        payload: { userId: revokeTargetId, grant: false }, // no-op revoke on a throwaway user
      });
      expect(res.statusCode).toBe(expected);
    });
  });

  describe("POST /api/v1/stores/:storeId/posts (that store's admin or superadmin)", () => {
    const cases: [string, () => string, number][] = [
      ["plain user", () => plainUserToken, 403],
      ["wrong-store admin (adminB on storeA)", () => adminBToken, 403],
      ["correct-store admin (adminA on storeA)", () => adminAToken, 201],
      ["superadmin", () => superadminToken, 201],
    ];
    it.each(cases)("%s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/stores/${storeAId}/posts`,
        headers: authHeader(getToken()),
        payload: {
          type: "image",
          caption: "matrix test",
          media: [{ url: "http://example.test/x.jpg", position: 0 }],
        },
      });
      expect(res.statusCode).toBe(expected);
      if (res.statusCode === 201) {
        await prisma.post.delete({ where: { id: res.json().post.id } });
        await prisma.store.update({
          where: { id: storeAId },
          data: { postsCount: { decrement: 1 } },
        });
      }
    });

    it("unauthenticated -> 401", async () => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/stores/${storeAId}/posts`,
        payload: { type: "image", caption: "x", media: [{ url: "x", position: 0 }] },
      });
      expect(res.statusCode).toBe(401);
    });
  });

  describe("DELETE /api/v1/posts/:id (owning store's admin or superadmin)", () => {
    async function makePost(): Promise<string> {
      const post = await prisma.post.create({
        data: { storeId: storeAId, type: "image", caption: "to-delete" },
      });
      await prisma.store.update({
        where: { id: storeAId },
        data: { postsCount: { increment: 1 } },
      });
      return post.id;
    }

    it("plain user -> 403", async () => {
      const postId = await makePost();
      const res = await app.inject({
        method: "DELETE",
        url: `/api/v1/posts/${postId}`,
        headers: authHeader(plainUserToken),
      });
      expect(res.statusCode).toBe(403);
    });

    it("wrong-store admin -> 403", async () => {
      const postId = await makePost();
      const res = await app.inject({
        method: "DELETE",
        url: `/api/v1/posts/${postId}`,
        headers: authHeader(adminBToken),
      });
      expect(res.statusCode).toBe(403);
    });

    it("correct-store admin -> 200", async () => {
      const postId = await makePost();
      const res = await app.inject({
        method: "DELETE",
        url: `/api/v1/posts/${postId}`,
        headers: authHeader(adminAToken),
      });
      expect(res.statusCode).toBe(200);
    });

    it("superadmin -> 200", async () => {
      const postId = await makePost();
      const res = await app.inject({
        method: "DELETE",
        url: `/api/v1/posts/${postId}`,
        headers: authHeader(superadminToken),
      });
      expect(res.statusCode).toBe(200);
    });
  });

  describe("POST /api/v1/stores/:storeId/stories (that store's admin or superadmin)", () => {
    const cases: [string, () => string, number][] = [
      ["plain user", () => plainUserToken, 403],
      ["wrong-store admin", () => adminBToken, 403],
      ["correct-store admin", () => adminAToken, 201],
      ["superadmin", () => superadminToken, 201],
    ];
    it.each(cases)("%s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/stores/${storeAId}/stories`,
        headers: authHeader(getToken()),
        payload: { mediaUrl: "http://example.test/s.jpg", mediaType: "image" },
      });
      expect(res.statusCode).toBe(expected);
      if (res.statusCode === 201) {
        await prisma.story.delete({ where: { id: res.json().story.id } });
      }
    });
  });

  describe("POST /api/v1/media/upload-url (any admin or superadmin, not plain user)", () => {
    const cases: [string, () => string, number][] = [
      ["plain user", () => plainUserToken, 403],
      ["admin (any store)", () => adminAToken, 200],
      ["superadmin", () => superadminToken, 200],
    ];
    it.each(cases)("%s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: "/api/v1/media/upload-url",
        headers: authHeader(getToken()),
        payload: { fileExt: "jpg", folder: "posts" },
      });
      expect(res.statusCode).toBe(expected);
    });
  });

  describe("GET routes require only authentication, any role", () => {
    it.each([
      ["plain user", () => plainUserToken],
      ["admin", () => adminAToken],
      ["superadmin", () => superadminToken],
    ])("%s -> 200 on GET /api/v1/stores", async (_label, getToken) => {
      const res = await app.inject({
        method: "GET",
        url: "/api/v1/stores",
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(200);
    });

    it("unauthenticated -> 401", async () => {
      const res = await app.inject({ method: "GET", url: "/api/v1/stores" });
      expect(res.statusCode).toBe(401);
    });
  });
});
