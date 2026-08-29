import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { config } from "../src/config.js";
import { prisma } from "../src/db.js";
import { requestOtp } from "../src/auth/otpStore.js";
import { createSession, findActiveSession, rotateSession } from "../src/auth/session.js";
import { type App } from "./helpers.js";

// Regressions for defects found by a pre-launch audit of the live API. Each of
// these reproduced against a running server, and each was silent — nothing in
// the existing suite failed while they were present.
describe("audit regressions", () => {
  let app: App;
  const userIds: string[] = [];
  const storeIds: string[] = [];
  const phones: string[] = [];

  const phone = () => {
    const p = `+99318${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    phones.push(p);
    return p;
  };

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.post.deleteMany({ where: { storeId: { in: storeIds } } });
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.session.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await prisma.otpCode.deleteMany({ where: { phone: { in: phones } } });
  });

  async function makeUser(role: "user" | "admin" | "superadmin" = "user") {
    const user = await prisma.user.create({
      data: { phone: phone(), name: "Audit Fixture", role },
    });
    userIds.push(user.id);
    return user;
  }

  // The OTP attempts counter was written inside the same transaction that then
  // threw to signal failure — so every increment was rolled back, `attempts`
  // never left 0, and the lockout never armed. A number could be brute-forced
  // without limit.
  describe("OTP lockout actually arms", () => {
    it("counts wrong attempts and locks after OTP_MAX_ATTEMPTS", async () => {
      const p = phone();
      await requestOtp(p);

      const seen: (number | undefined)[] = [];
      let locked = false;

      for (let i = 0; i < config.OTP_MAX_ATTEMPTS; i++) {
        const res = await app.inject({
          method: "POST",
          url: "/api/v1/auth/otp/verify",
          payload: { phone: p, code: "000000", name: "x" },
        });
        const body = res.json();
        if (body.error === "OTP_LOCKED") {
          locked = true;
          break;
        }
        expect(res.statusCode).toBe(401);
        seen.push(body.attemptsRemaining);
      }

      // The counter must actually move — this is the exact assertion that would
      // have caught the rollback bug, where every response said the same number.
      expect(new Set(seen).size).toBeGreaterThan(1);
      expect(seen[0]).toBeGreaterThan(seen[seen.length - 1]!);

      const row = await prisma.otpCode.findUnique({ where: { phone: p } });
      expect(row?.attempts ?? 0).toBeGreaterThan(0);

      if (!locked) {
        const res = await app.inject({
          method: "POST",
          url: "/api/v1/auth/otp/verify",
          payload: { phone: p, code: "000000", name: "x" },
        });
        expect(res.json().error).toBe("OTP_LOCKED");
      }
    });

    it("still rolls back for NameRequiredError, keeping the code usable", async () => {
      const p = phone();
      const { code } = await requestOtp(p);

      const first = await app.inject({
        method: "POST",
        url: "/api/v1/auth/otp/verify",
        payload: { phone: p, code },
      });
      expect(first.json().error).toBe("NAME_REQUIRED");

      // The rollback is deliberate here: the same code must still work.
      const second = await app.inject({
        method: "POST",
        url: "/api/v1/auth/otp/verify",
        payload: { phone: p, code, name: "Now With A Name" },
      });
      expect(second.statusCode).toBe(200);
      userIds.push(second.json().user.id);
    });
  });

  // findActiveSession reads without a lock and the revoke was unconditional, so
  // N concurrent refreshes with one token each minted their own 30-day session
  // family. Sequential replay already failed, which is what hid it.
  describe("refresh token rotation is single-use under concurrency", () => {
    it("lets exactly one of N parallel rotations win", async () => {
      const user = await makeUser();
      const { refreshToken } = await createSession(user.id, "audit");

      const attempts = await Promise.allSettled(
        Array.from({ length: 8 }, async () => {
          const session = await findActiveSession(refreshToken);
          return rotateSession(session);
        })
      );

      const won = attempts.filter((a) => a.status === "fulfilled").length;
      expect(won).toBe(1);

      const live = await prisma.session.count({
        where: { userId: user.id, revokedAt: null },
      });
      expect(live).toBe(1);
    });
  });

  // A user could point avatarUrl at ANY same-origin media URL (post images are
  // handed out by GET /feed) and, on deleting their own account, take that file
  // with them. Ownership was never checked.
  describe("avatarUrl cannot target arbitrary media", () => {
    it("rejects a media URL outside the avatars folder", async () => {
      const user = await makeUser();
      const { accessToken } = await loginAs(user.id);

      const res = await app.inject({
        method: "PATCH",
        url: "/api/v1/users/me",
        headers: { authorization: `Bearer ${accessToken}` },
        payload: { avatarUrl: `${config.MEDIA_PUBLIC_BASE_URL}/posts/victim.jpg` },
      });
      expect(res.statusCode).toBe(400);
    });

    it("still accepts a legitimate avatars/ URL and a non-media string", async () => {
      const user = await makeUser();
      const { accessToken } = await loginAs(user.id);

      for (const avatarUrl of [
        `${config.MEDIA_PUBLIC_BASE_URL}/avatars/mine.jpg`,
        "https://example.com/external.jpg",
        "",
      ]) {
        const res = await app.inject({
          method: "PATCH",
          url: "/api/v1/users/me",
          headers: { authorization: `Bearer ${accessToken}` },
          payload: { avatarUrl },
        });
        expect(res.statusCode, `should accept ${JSON.stringify(avatarUrl)}`).toBe(200);
      }
    });
  });

  // MySQL matches posts.id case-insensitively and ignores trailing spaces, but
  // the batch dedup was an exact-match JS Map — so 1000 spellings of one uuid
  // incremented every counter 1000 times in a single request.
  describe("interaction batch cannot be amplified by id spelling", () => {
    it("collapses case and padding variants of the same post id", async () => {
      const admin = await makeUser("admin");
      const store = await prisma.store.create({
        data: { name: "Audit Counter Store", phone: phone(), createdById: admin.id },
      });
      storeIds.push(store.id);
      const post = await prisma.post.create({
        data: { storeId: store.id, type: "image", caption: "counter" },
      });

      const user = await makeUser();
      const { accessToken } = await loginAs(user.id);

      const variants = [
        post.id,
        post.id.toUpperCase(),
        `${post.id} `,
        `${post.id}  `,
        post.id.replace(/^(.{8})/, (m) => m.toUpperCase()),
      ];

      const res = await app.inject({
        method: "POST",
        url: "/api/v1/posts/interactions",
        headers: { authorization: `Bearer ${accessToken}` },
        payload: { items: variants.map((postId) => ({ postId, views: 1, sent: 1, shares: 1 })) },
      });
      expect(res.statusCode).toBe(200);

      const after = await prisma.post.findUniqueOrThrow({ where: { id: post.id } });
      // An honest client can produce at most 1 per field per flush.
      expect(after.viewsCount).toBe(1);
      expect(after.sentCount).toBe(1);
      expect(after.sharesCount).toBe(1);
    });
  });

  // deletePostCascade dropped the post's likes but never decremented the store
  // total, so it drifted upward permanently — while the schema claimed it could
  // not drift.
  describe("store.likesCount survives post deletion", () => {
    it("sheds exactly the deleted post's likes", async () => {
      const admin = await makeUser("admin");
      const store = await prisma.store.create({
        data: { name: "Audit Likes Store", phone: phone(), createdById: admin.id },
      });
      storeIds.push(store.id);
      // role:"admin" alone is not enough — deleting a post checks store-admin
      // MEMBERSHIP, so the join row has to exist for the token to carry the
      // store in its claims.
      await prisma.storeAdmin.create({ data: { storeId: store.id, userId: admin.id } });
      const post = await prisma.post.create({
        data: { storeId: store.id, type: "image", caption: "likes" },
      });

      const liker1 = await makeUser();
      const liker2 = await makeUser();
      for (const u of [liker1, liker2]) {
        const { accessToken } = await loginAs(u.id);
        const res = await app.inject({
          method: "POST",
          url: `/api/v1/posts/${post.id}/like`,
          headers: { authorization: `Bearer ${accessToken}` },
        });
        expect(res.statusCode).toBe(200);
      }

      const before = await prisma.store.findUniqueOrThrow({ where: { id: store.id } });
      expect(before.likesCount).toBe(2);

      const { accessToken: adminToken } = await loginAs(admin.id);
      const del = await app.inject({
        method: "DELETE",
        url: `/api/v1/posts/${post.id}`,
        headers: { authorization: `Bearer ${adminToken}` },
      });
      expect(del.statusCode).toBe(200);

      const after = await prisma.store.findUniqueOrThrow({ where: { id: store.id } });
      expect(after.likesCount).toBe(0);
    });
  });

  /** Mints a real access token for an existing user, via the OTP flow so the
   * claims are produced the same way production produces them. */
  async function loginAs(userId: string): Promise<{ accessToken: string }> {
    const user = await prisma.user.findUniqueOrThrow({ where: { id: userId } });
    const { code } = await requestOtp(user.phone);
    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/otp/verify",
      payload: { phone: user.phone, code, name: user.name || "Audit" },
    });
    expect(res.statusCode).toBe(200);
    return { accessToken: res.json().accessToken };
  }
});
