import type { Session } from "@prisma/client";
import { randomUUID } from "node:crypto";

import { prisma } from "../db.js";
import { config } from "../config.js";
import { generateRefreshToken, hashToken } from "../lib/crypto.js";
import { withRetry } from "../lib/withRetry.js";

export class SessionInvalidError extends Error {
  constructor() {
    super("Refresh session is invalid, expired, or revoked");
  }
}

/** Sliding expiry: every row — the login's root and each refresh's successor —
 * gets a full window from the moment it is issued, so a session only lapses on
 * a device that has not refreshed in REFRESH_TOKEN_TTL_DAYS. */
function expiryFromNow(): Date {
  return new Date(Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000);
}

/** Whether a row may still be presented as a refresh token: live, or rotated
 * away so recently that the presenter plausibly never received the successor
 * (a lost response, or a second browser tab racing on the same cookie). A
 * revoked (logged-out) or expired row never qualifies, whatever its rotatedAt. */
function isPresentable(session: Session, now: Date): boolean {
  if (session.revokedAt !== null || session.expiresAt <= now) return false;
  if (session.rotatedAt === null) return true;
  return session.rotatedAt.getTime() > now.getTime() - config.REFRESH_REUSE_GRACE_SECONDS * 1000;
}

/** The family a row belongs to. familyId has no database default (Prisma fills
 * it), so a build that predates the column and is still serving while the
 * migration is already applied inserts '' on a non-strict MySQL. Left alone,
 * every such row — across every user — would share the one '' family, and one
 * person's logout would revoke all of them. A row without a family is its own
 * root instead. */
function familyOf(session: Pick<Session, "id" | "familyId">): string {
  return session.familyId || session.id;
}

export async function createSession(
  userId: string,
  deviceInfo?: string
): Promise<{ session: Session; refreshToken: string }> {
  const refreshToken = generateRefreshToken();
  // The root row is its own family; every later rotation and sibling inherits
  // the id, which is what lets logout end all of them at once.
  const id = randomUUID();
  const session = await prisma.session.create({
    data: {
      id,
      familyId: id,
      userId,
      tokenHash: hashToken(refreshToken),
      deviceInfo: deviceInfo ?? null,
      expiresAt: expiryFromNow(),
    },
  });
  return { session, refreshToken };
}

/** Looks up the session for a raw refresh token, throwing unless it can still
 * be presented (see isPresentable). Callers get back the plain session row. */
export async function findActiveSession(refreshToken: string): Promise<Session> {
  const session = await prisma.session.findUnique({
    where: { tokenHash: hashToken(refreshToken) },
  });
  if (!session || !isPresentable(session, new Date())) {
    throw new SessionInvalidError();
  }
  return session;
}

/** Rotates a refresh token on use: retires the presented row and issues a new
 * one in the same family, so a token replayed later is a dead end.
 *
 * The retire is a compare-and-swap (`rotatedAt: null` in the WHERE), not a
 * plain update. findActiveSession reads without a lock, so N concurrent
 * refreshes with the SAME token all see it live; with an unconditional update
 * every one of them "won" the row and minted its own family — eight parallel
 * requests produced eight, from a single token. Exactly one flips null →
 * timestamp.
 *
 * The losers are no longer rejected, though. Strict single-use meant a client
 * whose refresh RESPONSE was lost (receive timeout, app suspended mid-request,
 * two browser tabs racing on one cookie) was left holding a token the server
 * had already retired, and its very next refresh logged the device out — the
 * "re-login every 15 minutes" report. So for REFRESH_REUSE_GRACE_SECONDS after
 * a rotation the retired token is still honoured and the caller gets a live
 * SIBLING row of its own (only the successor's hash is stored, so the identical
 * pair cannot be re-sent); the winner's row stays live too. Past the grace a
 * replay is treated as exactly that — 401 for the replayed token, and nothing
 * else in the family is touched. */
export async function rotateSession(
  oldSession: Session
): Promise<{ session: Session; refreshToken: string }> {
  // withRetry like every other contended write in the codebase. N refreshes
  // arriving on one token all queue on the same row, so this is exactly the
  // shape that makes MySQL roll a side back and makes Prisma give up waiting
  // for a pooled connection — and the answer was a 500, which the app treats
  // as "refresh failed" and turns into a logout. The retried transaction
  // re-runs the compare-and-swap from scratch, which is what makes it safe:
  // the rolled-back or never-started attempt left nothing behind, and a
  // SessionInvalidError is not retryable and propagates unchanged.
  return withRetry(() => prisma.$transaction(async (tx) => {
    const now = new Date();
    const claimed = await tx.session.updateMany({
      where: { id: oldSession.id, rotatedAt: null, revokedAt: null },
      data: { rotatedAt: now },
    });
    if (claimed.count === 0) {
      // Someone else retired this row first, or the caller is replaying a
      // token retired moments ago. The row the caller holds predates the CAS,
      // so re-read it — the UPDATE above waited for the winner's commit — and
      // honour it only inside the grace.
      const current = await tx.session.findUnique({ where: { id: oldSession.id } });
      if (!current || !isPresentable(current, now)) throw new SessionInvalidError();
    }
    const refreshToken = generateRefreshToken();
    const session = await tx.session.create({
      data: {
        userId: oldSession.userId,
        familyId: familyOf(oldSession),
        tokenHash: hashToken(refreshToken),
        deviceInfo: oldSession.deviceInfo,
        expiresAt: expiryFromNow(),
      },
    });
    return { session, refreshToken };
  }));
}

/** Logout. Ends every row of the presented token's family, not just the row
 * itself: a lost refresh response or a racing second tab leaves a live sibling
 * the client never saw (see rotateSession), and "sign out" has to reach those
 * too.
 *
 * Only a token that could still refresh may do it, though — the same rule
 * (isPresentable) as /auth/refresh, so a token rotated inside the grace still
 * signs out the phone whose logout raced its own refresh, while one rotated
 * away long ago, or expired, is a no-op. Accepting any token of the family
 * would have let a stale one — captured in transit past the grace, sitting in
 * a device backup — end the owner's live session, an authority a dead token
 * never had before. An unknown token is likewise a no-op: logout is
 * idempotent. */
export async function revokeSessionFamily(refreshToken: string): Promise<void> {
  const now = new Date();
  const session = await prisma.session.findUnique({
    where: { tokenHash: hashToken(refreshToken) },
  });
  if (!session || !isPresentable(session, now)) return;
  const familyId = familyOf(session);
  await prisma.session.updateMany({
    // `id: familyId` is the root itself, which a '' family (see familyOf) has
    // not stamped with its own id; for every other row it is already matched
    // by familyId.
    where: { OR: [{ familyId }, { id: familyId }], revokedAt: null },
    data: { revokedAt: now },
  });
}
