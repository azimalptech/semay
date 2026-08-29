import type { Session } from "@prisma/client";

import { prisma } from "../db.js";
import { config } from "../config.js";
import { generateRefreshToken, hashToken } from "../lib/crypto.js";

export class SessionInvalidError extends Error {
  constructor() {
    super("Refresh session is invalid, expired, or revoked");
  }
}

export async function createSession(
  userId: string,
  deviceInfo?: string
): Promise<{ session: Session; refreshToken: string }> {
  const refreshToken = generateRefreshToken();
  const expiresAt = new Date(
    Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000
  );
  const session = await prisma.session.create({
    data: {
      userId,
      tokenHash: hashToken(refreshToken),
      deviceInfo: deviceInfo ?? null,
      expiresAt,
    },
  });
  return { session, refreshToken };
}

/** Looks up the session for a raw refresh token, throwing if it's missing,
 * revoked, or expired. Callers get back the plain session row (userId etc). */
export async function findActiveSession(refreshToken: string): Promise<Session> {
  const session = await prisma.session.findUnique({
    where: { tokenHash: hashToken(refreshToken) },
  });
  const now = new Date();
  if (!session || session.revokedAt || session.expiresAt <= now) {
    throw new SessionInvalidError();
  }
  return session;
}

/** Rotates a refresh token on use: revokes the old session row and issues a new
 * one for the same user, so a leaked-and-replayed old token is a dead end.
 *
 * The revoke is a compare-and-swap (`revokedAt: null` in the WHERE), not a
 * plain update, and that is the whole correctness argument. findActiveSession
 * reads without a lock, so N concurrent refreshes with the SAME token all see
 * it live; with an unconditional update every one of them succeeded and minted
 * its own 30-day session family — eight parallel requests produced eight, from
 * a single token. Sequential replay was already a dead end, which is what made
 * this look safe. Now exactly one request flips null → timestamp; the losers
 * match no row and are rejected like any other replay. */
export async function rotateSession(
  oldSession: Session
): Promise<{ session: Session; refreshToken: string }> {
  return prisma.$transaction(async (tx) => {
    const claimed = await tx.session.updateMany({
      where: { id: oldSession.id, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    if (claimed.count === 0) throw new SessionInvalidError();
    const refreshToken = generateRefreshToken();
    const expiresAt = new Date(
      Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 24 * 60 * 60 * 1000
    );
    const session = await tx.session.create({
      data: {
        userId: oldSession.userId,
        tokenHash: hashToken(refreshToken),
        deviceInfo: oldSession.deviceInfo,
        expiresAt,
      },
    });
    return { session, refreshToken };
  });
}

export async function revokeSession(sessionId: string): Promise<void> {
  await prisma.session.update({
    where: { id: sessionId },
    data: { revokedAt: new Date() },
  });
}
