import type { Prisma, Role } from "@prisma/client";

import { prisma } from "../db.js";

export interface Claims {
  userId: string;
  role: Role;
  storeIds: string[];
  claimsVersion: number;
}

/**
 * The full claims set for a user: role + which stores they admin (derived
 * from the store_admins junction table) + the claims_version embedded in
 * access JWTs. Called at login/refresh time (fresh read) — never cached
 * beyond a single request.
 */
export async function getClaimsForUser(userId: string): Promise<Claims> {
  const user = await prisma.user.findUniqueOrThrow({
    where: { id: userId },
    select: { role: true, claimsVersion: true },
  });
  const storeAdminRows = await prisma.storeAdmin.findMany({
    where: { userId },
    select: { storeId: true },
  });
  return {
    userId,
    role: user.role,
    storeIds: storeAdminRows.map((r) => r.storeId),
    claimsVersion: user.claimsVersion,
  };
}

/**
 * Bumps claims_version for every affected user in the same transaction as a
 * role/storeIds change (setStoreAdmin, deleteStore's demote-cascade, etc.) —
 * this is what makes a stale access JWT self-heal instead of silently
 * granting/denying based on an out-of-date snapshot. Callers pass an active
 * transaction client so this participates in the same commit.
 */
export async function bumpClaimsVersion(
  tx: Pick<typeof prisma, "user">,
  userId: string
): Promise<void> {
  await tx.user.update({
    where: { id: userId },
    data: { claimsVersion: { increment: 1 } },
  });
}
