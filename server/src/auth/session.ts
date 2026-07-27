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
 * one for the same user, so a leaked-and-replayed old token is a dead end. */
export async function rotateSession(
  oldSession: Session
): Promise<{ session: Session; refreshToken: string }> {
  return prisma.$transaction(async (tx) => {
    await tx.session.update({
      where: { id: oldSession.id },
      data: { revokedAt: new Date() },
    });
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
