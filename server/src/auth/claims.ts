import type { Prisma, Role } from "@prisma/client";

import { prisma } from "../db.js";
import { publish } from "../realtime/bus.js";

/** The account behind this id has been deleted (tombstoned). Surfaces as 401 —
 * the caller's credentials are no longer valid for anything. */
export class AccountDeletedError extends Error {
  constructor() {
    super("Account has been deleted");
    this.name = "AccountDeletedError";
  }
}

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
    select: { role: true, claimsVersion: true, deletedAt: true },
  });
  // A deleted account is a tombstone row that only exists so retained orders
  // keep a valid FK — it must never yield usable claims again. revocation.ts
  // covers the fast requireAuth path, but that set is per-process and clears on
  // restart; this is the durable check behind it, on the one path that already
  // reads the row so it costs nothing extra.
  if (user.deletedAt) throw new AccountDeletedError();
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
  // Tell any open WebSocket for this user to drop and re-auth. Replaces the
  // gateway's old per-connection 30s DB poll: instant instead of up to 30s, and
  // costs nothing when nothing changes. Fire-and-forget — the caller is inside a
  // transaction that may still roll back, and a spurious reconnect is harmless
  // (the client re-authenticates and carries on), whereas awaiting a pub-sub
  // round trip inside the transaction would hold locks for no benefit.
  publish(`user:${userId}:claims`, { type: "remove", id: userId });
}
