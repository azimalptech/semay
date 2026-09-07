import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { createSession } from "../src/auth/session.js";
import { createOrGetChat } from "../src/chats/service.js";
import { setStoreAdmin } from "../src/stores/service.js";
import { prisma } from "../src/db.js";
import { hashToken } from "../src/lib/crypto.js";
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

  // Chat routes are participant-gated, not role-gated: the chat's own customer,
  // an admin of ITS store, or superadmin. A wrong-store admin and an unrelated
  // customer are both outsiders. Receipts matter here because the chat
  // reliability pass widened what a receipt does (realtime roll-up + a badge
  // push fan-out to the store's admins), so who may post one must stay exact.
  describe("chat routes (participants only)", () => {
    let chatId: string;
    let strangerToken: string;
    let strangerId: string;

    beforeAll(async () => {
      chatId = (await createOrGetChat(plainUserId, storeAId)).id;
      const stranger = await createUserWithToken("user");
      strangerId = stranger.userId;
      strangerToken = stranger.token;
    });

    afterAll(async () => {
      // The chat itself goes with storeA's cascade in the outer afterAll.
      await cleanupUsers([strangerId]);
    });

    const receiptCases: [string, () => string, number][] = [
      ["participant customer", () => plainUserToken, 200],
      ["correct-store admin", () => adminAToken, 200],
      ["superadmin", () => superadminToken, 200],
      ["wrong-store admin", () => adminBToken, 403],
      ["unrelated customer", () => strangerToken, 403],
    ];
    it.each(receiptCases)("POST /chats/:id/receipts: %s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/chats/${chatId}/receipts`,
        headers: authHeader(getToken()),
        payload: { status: "delivered" },
      });
      expect(res.statusCode).toBe(expected);
    });

    const messageCases: [string, () => string, number][] = [
      ["participant customer", () => plainUserToken, 201],
      ["correct-store admin", () => adminAToken, 201],
      ["superadmin", () => superadminToken, 201],
      ["wrong-store admin", () => adminBToken, 403],
      ["unrelated customer", () => strangerToken, 403],
    ];
    it.each(messageCases)("POST /chats/:id/messages: %s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/chats/${chatId}/messages`,
        headers: authHeader(getToken()),
        payload: { text: "matrix" },
      });
      expect(res.statusCode).toBe(expected);
    });

    it("unauthenticated -> 401", async () => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/chats/${chatId}/receipts`,
        payload: { status: "read" },
      });
      expect(res.statusCode).toBe(401);
    });
  });

  // reels-in-feed: GET /feed lost its hard type filter and grew an optional
  // `?type=`; GET /reels is unchanged. Neither is role-gated — any signed-in
  // user, admin or superadmin reads the same public stream — and the filter
  // must not open a side door: an unknown type is a 400, never a wider query.
  describe("reels-in-feed: GET /api/v1/feed and GET /api/v1/reels (any authenticated role)", () => {
    const roles: [string, () => string][] = [
      ["plain user", () => plainUserToken],
      ["admin", () => adminAToken],
      ["superadmin", () => superadminToken],
    ];

    it.each(roles)("%s -> 200 on GET /feed", async (_label, getToken) => {
      const res = await app.inject({
        method: "GET",
        url: "/api/v1/feed?limit=1",
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(200);
    });

    it.each(roles)("%s -> 200 on GET /feed?type=reel", async (_label, getToken) => {
      const res = await app.inject({
        method: "GET",
        url: "/api/v1/feed?type=reel&limit=1",
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(200);
    });

    it.each(roles)("%s -> 200 on GET /reels", async (_label, getToken) => {
      const res = await app.inject({
        method: "GET",
        url: "/api/v1/reels?limit=1",
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(200);
    });

    it("unknown ?type= -> 400 for a signed-in user", async () => {
      const res = await app.inject({
        method: "GET",
        url: "/api/v1/feed?type=story",
        headers: authHeader(plainUserToken),
      });
      expect(res.statusCode).toBe(400);
    });

    it.each([
      ["GET /feed", "/api/v1/feed"],
      ["GET /feed?type=reel", "/api/v1/feed?type=reel"],
      ["GET /reels", "/api/v1/reels"],
    ])("unauthenticated -> 401 on %s", async (_label, url) => {
      const res = await app.inject({ method: "GET", url });
      expect(res.statusCode).toBe(401);
    });
  });

  // chat-delete: DELETE /chats/:id now hides the caller's side's history (a
  // cutoff by message id) and GET /chats/:id/messages reads through that
  // cutoff — both stay participant-gated exactly like receipts/messages above.
  // A dedicated chat, because the DELETE cases really do hide it for the
  // customer and for storeA's admins, and the block above must keep
  // exercising an unhidden thread.
  describe("chat-delete: DELETE /chats/:id and GET /chats/:id/messages (participants only)", () => {
    let chatId: string;
    let customerId: string;
    let customerToken: string;
    let strangerId: string;
    let strangerToken: string;

    beforeAll(async () => {
      const customer = await createUserWithToken("user");
      customerId = customer.userId;
      customerToken = customer.token;
      chatId = (await createOrGetChat(customerId, storeAId)).id;
      const stranger = await createUserWithToken("user");
      strangerId = stranger.userId;
      strangerToken = stranger.token;
    });

    afterAll(async () => {
      // The chat itself goes with storeA's cascade in the outer afterAll.
      await cleanupUsers([customerId, strangerId]);
    });

    const readCases: [string, () => string, number][] = [
      ["participant customer", () => customerToken, 200],
      ["correct-store admin", () => adminAToken, 200],
      ["superadmin", () => superadminToken, 200],
      ["wrong-store admin", () => adminBToken, 403],
      ["unrelated customer", () => strangerToken, 403],
    ];
    it.each(readCases)("GET /chats/:id/messages: %s -> %i", async (_label, getToken, expected) => {
      const res = await app.inject({
        method: "GET",
        url: `/api/v1/chats/${chatId}/messages`,
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(expected);
    });

    // Outsiders first, so each 403 can be checked against a row nobody has
    // hidden yet; the participants then hide it for real (customer side, then
    // the store side twice — superadmin counts as the store's side).
    const deleteCases: [string, () => string, number][] = [
      ["wrong-store admin", () => adminBToken, 403],
      ["unrelated customer", () => strangerToken, 403],
      ["participant customer", () => customerToken, 200],
      ["correct-store admin", () => adminAToken, 200],
      ["superadmin", () => superadminToken, 200],
    ];
    it.each(deleteCases)("DELETE /chats/:id: %s -> %i", async (_label, getToken, expected) => {
      // No payload and no content-type: Fastify answers a JSON content-type
      // with an empty body with 400, and the app's Dio client sends neither.
      const res = await app.inject({
        method: "DELETE",
        url: `/api/v1/chats/${chatId}`,
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(expected);
      if (expected === 403) {
        const row = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
        expect(row.hiddenByUserAt).toBeNull();
        expect(row.hiddenByAdminAt).toBeNull();
        expect(row.hiddenByUserUpToId).toBeNull();
        expect(row.hiddenByAdminUpToId).toBeNull();
      }
    });

    it("unauthenticated -> 401", async () => {
      const res = await app.inject({ method: "DELETE", url: `/api/v1/chats/${chatId}` });
      expect(res.statusCode).toBe(401);
    });
  });

  // quick-replies: the app's Add sheet was fixed to actually reach POST, and
  // none of the four routes had a matrix case. GET/POST are gated by
  // requireStoreAdmin on the URL's store; PATCH/DELETE take a bare reply id,
  // look the row up and gate on ITS store (assertCanManage) — that lookup is
  // what keeps a wrong-store admin from editing another store's canned
  // replies by guessing ids, so it gets the same four roles.
  describe("quick-replies: GET/POST /stores/:storeId/quick-replies, PATCH/DELETE /quick-replies/:id (that store's admin or superadmin)", () => {
    let replyId: string;

    const roles: [string, () => string, boolean][] = [
      ["plain user", () => plainUserToken, false],
      ["wrong-store admin (adminB on storeA)", () => adminBToken, false],
      ["correct-store admin (adminA on storeA)", () => adminAToken, true],
      ["superadmin", () => superadminToken, true],
    ];

    async function makeReply(): Promise<string> {
      const row = await prisma.storeQuickReply.create({
        data: { storeId: storeAId, text: "matrix quick reply", position: 0 },
      });
      return row.id.toString();
    }

    beforeAll(async () => {
      replyId = await makeReply();
    });

    afterAll(async () => {
      await prisma.storeQuickReply.deleteMany({ where: { storeId: storeAId } });
    });

    it.each(roles)("GET /stores/:storeId/quick-replies: %s", async (_label, getToken, allowed) => {
      const res = await app.inject({
        method: "GET",
        url: `/api/v1/stores/${storeAId}/quick-replies`,
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(allowed ? 200 : 403);
    });

    it.each(roles)("POST /stores/:storeId/quick-replies: %s", async (_label, getToken, allowed) => {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/stores/${storeAId}/quick-replies`,
        headers: authHeader(getToken()),
        payload: { text: "matrix", position: 1 },
      });
      expect(res.statusCode).toBe(allowed ? 201 : 403);
    });

    it.each(roles)("PATCH /quick-replies/:id: %s", async (_label, getToken, allowed) => {
      const res = await app.inject({
        method: "PATCH",
        url: `/api/v1/quick-replies/${replyId}`,
        headers: authHeader(getToken()),
        payload: { text: "matrix edited" },
      });
      expect(res.statusCode).toBe(allowed ? 200 : 403);
    });

    it.each(roles)("DELETE /quick-replies/:id: %s", async (_label, getToken, allowed) => {
      const id = await makeReply();
      const res = await app.inject({
        method: "DELETE",
        url: `/api/v1/quick-replies/${id}`,
        headers: authHeader(getToken()),
      });
      expect(res.statusCode).toBe(allowed ? 200 : 403);
      expect(await prisma.storeQuickReply.count({ where: { id: BigInt(id) } })).toBe(allowed ? 0 : 1);
    });

    it.each([
      ["GET", () => `/api/v1/stores/${storeAId}/quick-replies`],
      ["POST", () => `/api/v1/stores/${storeAId}/quick-replies`],
      ["PATCH", () => `/api/v1/quick-replies/${replyId}`],
      ["DELETE", () => `/api/v1/quick-replies/${replyId}`],
    ] as const)("unauthenticated -> 401 on %s", async (method, url) => {
      const res = await app.inject({ method, url: url() });
      expect(res.statusCode).toBe(401);
    });
  });

  // Neither route carries a bearer token: the credential is possession of a
  // refresh token the server would still accept — live, or rotated inside the
  // reuse grace. Rotated past the grace or expired, a token can neither refresh
  // nor sign anything out; /auth/logout stays 200 for it (idempotent) but the
  // live session is untouched. The full rotation contract is pinned in
  // tests/session.rotation.test.ts; this is the who-may-do-what slice.
  describe("sessions: POST /auth/refresh and /auth/logout (possession of a presentable refresh token)", () => {
    const graceMs = 60 * 1000;

    const refresh = (refreshToken: string) =>
      app.inject({ method: "POST", url: "/api/v1/auth/refresh", payload: { refreshToken } });
    const logout = (refreshToken: string) =>
      app.inject({ method: "POST", url: "/api/v1/auth/logout", payload: { refreshToken } });

    async function retirePastGrace(refreshToken: string): Promise<void> {
      await prisma.session.update({
        where: { tokenHash: hashToken(refreshToken) },
        data: { rotatedAt: new Date(Date.now() - graceMs - 1000) },
      });
    }

    it.each([
      ["plain user", () => plainUserId],
      ["store admin", () => adminAId],
      ["superadmin", () => superadminId],
    ])("refresh: live token -> 200, replayed past the grace -> 401 SESSION_INVALID, successor unaffected: %s", async (_label, getUserId) => {
      const { refreshToken } = await createSession(getUserId(), "matrix");
      const first = await refresh(refreshToken);
      expect(first.statusCode).toBe(200);

      await retirePastGrace(refreshToken);
      const replay = await refresh(refreshToken);
      expect(replay.statusCode).toBe(401);
      expect(replay.json().error).toBe("SESSION_INVALID");
      expect((await refresh(first.json().refreshToken)).statusCode).toBe(200);
    });

    it("logout: a token rotated inside the grace ends the family (200), and the live successor is 401", async () => {
      const { refreshToken } = await createSession(plainUserId, "matrix");
      const first = await refresh(refreshToken);
      expect(first.statusCode).toBe(200);

      expect((await logout(refreshToken)).statusCode).toBe(200);
      const replay = await refresh(first.json().refreshToken);
      expect(replay.statusCode).toBe(401);
      expect(replay.json().error).toBe("SESSION_INVALID");
    });

    it("logout: a token rotated past the grace is 200 but revokes nothing", async () => {
      const { refreshToken } = await createSession(plainUserId, "matrix");
      const first = await refresh(refreshToken);
      expect(first.statusCode).toBe(200);
      await retirePastGrace(refreshToken);

      expect((await logout(refreshToken)).statusCode).toBe(200);
      expect((await refresh(first.json().refreshToken)).statusCode).toBe(200);
    });

    it("logout: a token of another user's family never touches this one", async () => {
      const mine = await createSession(plainUserId, "matrix");
      const theirs = await createSession(adminBId, "matrix");

      expect((await logout(theirs.refreshToken)).statusCode).toBe(200);
      expect((await refresh(mine.refreshToken)).statusCode).toBe(200);
    });

    it("logout: an unknown token -> 200; no body -> 400 on both routes", async () => {
      expect((await logout("not-a-token")).statusCode).toBe(200);
      expect((await app.inject({ method: "POST", url: "/api/v1/auth/refresh", payload: {} })).statusCode).toBe(400);
      expect((await app.inject({ method: "POST", url: "/api/v1/auth/logout", payload: {} })).statusCode).toBe(400);
    });
  });
});
