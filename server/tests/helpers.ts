import type { Role } from "@prisma/client";
import type { FastifyInstance } from "fastify";

import { getClaimsForUser } from "../src/auth/claims.js";
import { prisma } from "../src/db.js";
import { signAccessToken } from "../src/lib/jwt.js";

/** Creates a real user row (bypassing the OTP flow, which is covered
 * elsewhere) and signs a real access token from their *actual* DB claims —
 * exercises the same signAccessToken/verifyAccessToken path production uses. */
export async function createUserWithToken(
  role: Role = "user"
): Promise<{ userId: string; token: string }> {
  const phone = `+9937${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
  const user = await prisma.user.create({ data: { phone, role } });
  const claims = await getClaimsForUser(user.id);
  return { userId: user.id, token: signAccessToken(claims) };
}

/** Re-signs a token reflecting the user's current DB claims — use after a
 * setup step (e.g. setStoreAdmin) changes role/storeIds mid-test. */
export async function refreshedToken(userId: string): Promise<string> {
  const claims = await getClaimsForUser(userId);
  return signAccessToken(claims);
}

export async function createStore(name: string, createdById: string) {
  return prisma.store.create({ data: { name, createdById } });
}

export function authHeader(token: string): { authorization: string } {
  return { authorization: `Bearer ${token}` };
}

export async function cleanupUsers(userIds: string[]): Promise<void> {
  await prisma.user.deleteMany({ where: { id: { in: userIds } } });
}

export async function cleanupStores(storeIds: string[]): Promise<void> {
  await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
}

export type App = FastifyInstance;
