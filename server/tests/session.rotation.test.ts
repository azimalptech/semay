import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { config } from "../src/config.js";
import { prisma } from "../src/db.js";
import {
  createSession,
  findActiveSession,
  rotateSession,
  SessionInvalidError,
} from "../src/auth/session.js";
import { generateRefreshToken, hashToken } from "../src/lib/crypto.js";
import { createUserWithToken, type App } from "./helpers.js";

// Sessions last until logout (owner decision). Rotation used to be strictly
// single-use: a refresh whose response never reached the client, or two
// browser tabs refreshing on one cookie, left the device holding a retired
// token and its next refresh logged it out — roughly every access-token TTL.
// These pin the replacement contract: a reuse grace that issues a live
// sibling, sliding expiry, and a logout that ends the whole family.
describe("sessions: rotation grace, sliding expiry, logout", () => {
  let app: App;
  let userId: string;
  let otherUserId: string;

  beforeAll(async () => {
    app = await buildApp();
    ({ userId } = await createUserWithToken());
    ({ userId: otherUserId } = await createUserWithToken());
  });

  afterAll(async () => {
    await app.close();
    await prisma.user.deleteMany({ where: { id: { in: [userId, otherUserId] } } });
  });

  async function refresh(refreshToken: string) {
    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/refresh",
      payload: { refreshToken },
    });
    const body = res.json() as { accessToken?: string; refreshToken?: string; error?: string };
    return { status: res.statusCode, body };
  }

  async function logout(refreshToken: string) {
    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/logout",
      payload: { refreshToken },
    });
    return res.statusCode;
  }

  const rowFor = (refreshToken: string) =>
    prisma.session.findUniqueOrThrow({ where: { tokenHash: hashToken(refreshToken) } });

  const graceMs = config.REFRESH_REUSE_GRACE_SECONDS * 1000;

  it("honours a just-rotated token inside the grace with a live sibling of its own", async () => {
    const { session: root, refreshToken: a } = await createSession(userId, "phone");

    const first = await refresh(a);
    expect(first.status).toBe(200);
    const b = first.body.refreshToken!;
    const retiredAt = (await rowFor(a)).rotatedAt;
    expect(retiredAt).not.toBeNull();

    // The client never saw `b` (lost response) and presents `a` again.
    const replay = await refresh(a);
    expect(replay.status).toBe(200);
    const c = replay.body.refreshToken!;
    expect(c).not.toBe(b);
    // The replay was served from the grace, not by retiring the row again:
    // rotatedAt is set by exactly one refresh (the compare-and-swap).
    expect((await rowFor(a)).rotatedAt).toEqual(retiredAt);

    // Both issues are real: each refreshes on its own, and they share the family.
    expect((await refresh(b)).status).toBe(200);
    expect((await refresh(c)).status).toBe(200);
    const family = await prisma.session.findMany({ where: { familyId: root.familyId } });
    expect(family).toHaveLength(5);
    expect(root.familyId).toBe(root.id);
  });

  // Without the compare-and-swap every in-grace replay would stamp a fresh
  // rotatedAt, turning the 60 s replay window into one that slides for as long
  // as a captured token keeps being presented. The backdated timestamp makes
  // the check independent of how fast two requests run.
  it("does not slide the grace window: a replay leaves rotatedAt untouched", async () => {
    const { refreshToken: a } = await createSession(userId, "phone");
    expect((await refresh(a)).status).toBe(200);

    const nearlyOut = new Date(Date.now() - graceMs + 5_000);
    await prisma.session.update({ where: { id: (await rowFor(a)).id }, data: { rotatedAt: nearlyOut } });

    expect((await refresh(a)).status).toBe(200);
    expect((await rowFor(a)).rotatedAt).toEqual(nearlyOut);
  });

  // The CAS predicate also carries `revokedAt: null`: a refresh that read the
  // row live but lost the race to a logout must not stamp rotatedAt onto the
  // revoked row and hand out a live sibling of a session that just ended.
  it("mints nothing for a refresh that lost the race to logout", async () => {
    const { session: root, refreshToken: a } = await createSession(userId, "phone");
    const stale = await findActiveSession(a);
    expect(await logout(a)).toBe(200);

    await expect(rotateSession(stale)).rejects.toBeInstanceOf(SessionInvalidError);
    const family = await prisma.session.findMany({ where: { familyId: root.familyId } });
    expect(family).toHaveLength(1);
    expect(family[0].rotatedAt).toBeNull();
    expect(family[0].revokedAt).not.toBeNull();
  });

  it("rejects a token replayed after the grace, and only that token", async () => {
    const { refreshToken: a } = await createSession(userId, "phone");
    const first = await refresh(a);
    expect(first.status).toBe(200);

    const row = await rowFor(a);
    await prisma.session.update({
      where: { id: row.id },
      data: { rotatedAt: new Date(Date.now() - graceMs - 1000) },
    });

    const replay = await refresh(a);
    expect(replay.status).toBe(401);
    expect(replay.body.error).toBe("SESSION_INVALID");

    // No family revocation: the successor is untouched.
    expect((await refresh(first.body.refreshToken!)).status).toBe(200);
  });

  it("lets every one of N concurrent refreshes with one token succeed", async () => {
    const { session: root, refreshToken } = await createSession(userId, "tabs");

    const results = await Promise.all(Array.from({ length: 8 }, () => refresh(refreshToken)));
    expect(results.map((r) => r.status)).toEqual(Array(8).fill(200));
    const issued = results.map((r) => r.body.refreshToken!);
    expect(new Set(issued).size).toBe(8);

    // Every racer got a working token, not just the CAS winner.
    for (const token of issued) {
      expect((await refresh(token)).status).toBe(200);
    }
    const rootRow = await prisma.session.findUniqueOrThrow({ where: { id: root.id } });
    expect(rootRow.rotatedAt).not.toBeNull();
    expect(rootRow.revokedAt).toBeNull();
  });

  it("slides the expiry forward on every refresh", async () => {
    const { refreshToken: a } = await createSession(userId, "phone");
    const soon = new Date(Date.now() + 86_400_000);
    await prisma.session.update({ where: { id: (await rowFor(a)).id }, data: { expiresAt: soon } });

    const res = await refresh(a);
    expect(res.status).toBe(200);

    const successor = await rowFor(res.body.refreshToken!);
    const expectedMs = Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 86_400_000;
    expect(Math.abs(successor.expiresAt.getTime() - expectedMs)).toBeLessThan(60_000);
    expect(successor.expiresAt.getTime()).toBeGreaterThan(soon.getTime());
  });

  it("rejects a token past its expiry", async () => {
    const { refreshToken: a } = await createSession(userId, "phone");
    await prisma.session.update({
      where: { id: (await rowFor(a)).id },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });
    const res = await refresh(a);
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("SESSION_INVALID");
  });

  it("logout ends the whole family, even for a token still inside the grace", async () => {
    const { session: root, refreshToken: a } = await createSession(userId, "phone");
    const first = await refresh(a);
    expect(first.status).toBe(200);
    const b = first.body.refreshToken!;

    // Signing out with the retired token (the client lost `b`) still works.
    expect(await logout(a)).toBe(200);

    expect((await refresh(b)).status).toBe(401);
    expect((await refresh(a)).status).toBe(401);
    const family = await prisma.session.findMany({ where: { familyId: root.familyId } });
    expect(family.every((row) => row.revokedAt !== null)).toBe(true);
  });

  // Logout takes the same rule as refresh: a token that could no longer refresh
  // carries no authority over the live session. Otherwise any stale token —
  // captured past the grace, left in a backup — could sign the owner out.
  it("logout with a token rotated past the grace is a no-op for the live successor", async () => {
    const { refreshToken: a } = await createSession(userId, "phone");
    const first = await refresh(a);
    expect(first.status).toBe(200);
    await prisma.session.update({
      where: { id: (await rowFor(a)).id },
      data: { rotatedAt: new Date(Date.now() - graceMs - 1000) },
    });

    expect(await logout(a)).toBe(200);

    const successor = await rowFor(first.body.refreshToken!);
    expect(successor.revokedAt).toBeNull();
    expect((await refresh(first.body.refreshToken!)).status).toBe(200);
  });

  it("logout with an expired token is a no-op", async () => {
    const { session: root, refreshToken: a } = await createSession(userId, "phone");
    await prisma.session.update({ where: { id: root.id }, data: { expiresAt: new Date(Date.now() - 1000) } });
    expect(await logout(a)).toBe(200);
    expect((await prisma.session.findUniqueOrThrow({ where: { id: root.id } })).revokedAt).toBeNull();
  });

  it("logout is idempotent for an unknown token", async () => {
    expect(await logout("not-a-token")).toBe(200);
  });

  // familyId has no database default, so a build that predates the column,
  // still serving after the migration was applied, writes '' on a non-strict
  // MySQL — for every user. Those rows must not collapse into one family.
  describe("a row without a family (written by the previous build) is its own family", () => {
    async function orphanRow(owner: string) {
      const refreshToken = generateRefreshToken();
      const session = await prisma.session.create({
        data: {
          userId: owner,
          familyId: "",
          tokenHash: hashToken(refreshToken),
          expiresAt: new Date(Date.now() + 86_400_000),
        },
      });
      return { session, refreshToken };
    }

    it("is never revoked by another user's logout", async () => {
      const mine = await orphanRow(userId);
      const theirs = await orphanRow(otherUserId);

      expect(await logout(mine.refreshToken)).toBe(200);

      expect((await rowFor(mine.refreshToken)).revokedAt).not.toBeNull();
      expect((await rowFor(theirs.refreshToken)).revokedAt).toBeNull();
      expect((await refresh(theirs.refreshToken)).status).toBe(200);
    });

    it("roots the family its successors inherit, and logout through a successor reaches it", async () => {
      const { session: root, refreshToken: a } = await orphanRow(userId);
      const first = await refresh(a);
      expect(first.status).toBe(200);
      const successor = await rowFor(first.body.refreshToken!);
      expect(successor.familyId).toBe(root.id);

      expect(await logout(first.body.refreshToken!)).toBe(200);
      expect((await prisma.session.findUniqueOrThrow({ where: { id: root.id } })).revokedAt).not.toBeNull();
      expect((await rowFor(first.body.refreshToken!)).revokedAt).not.toBeNull();
      expect((await refresh(a)).status).toBe(401);
    });
  });
});
