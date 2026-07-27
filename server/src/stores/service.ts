import { bumpClaimsVersion } from "../auth/claims.js";
import { prisma } from "../db.js";

/** Grants/revokes store-admin for a user. Revoking down to zero managed stores
 * demotes them back to role='user' — same transition deleteStoreCascade uses.
 * claims_version is always bumped so their next request/refresh sees the change
 * instead of riding out a stale access token. */
export async function setStoreAdmin(
  storeId: string,
  userId: string,
  grant: boolean
): Promise<void> {
  await prisma.$transaction(async (tx) => {
    if (grant) {
      await tx.storeAdmin.upsert({
        where: { storeId_userId: { storeId, userId } },
        create: { storeId, userId },
        update: {},
      });
      await tx.user.update({ where: { id: userId }, data: { role: "admin" } });
    } else {
      await tx.storeAdmin.deleteMany({ where: { storeId, userId } });
      const remaining = await tx.storeAdmin.count({ where: { userId } });
      if (remaining === 0) {
        await tx.user.update({ where: { id: userId }, data: { role: "user" } });
      }
    }
    await bumpClaimsVersion(tx, userId);
  });
}

/** Irreversible cascade delete. FK ON DELETE CASCADE on posts/stories/chats/
 * orders/leaderboard/quickReplies/notificationRequests/storeAdmins (see
 * schema.prisma) does the relational cleanup; this function's own job is only
 * the cross-entity side effect FKs can't express — demoting admins who end up
 * with zero managed stores after their storeAdmin rows cascade-delete. */
export async function deleteStoreCascade(storeId: string): Promise<void> {
  const admins = await prisma.storeAdmin.findMany({
    where: { storeId },
    select: { userId: true },
  });

  await prisma.$transaction(async (tx) => {
    await tx.store.delete({ where: { id: storeId } });
    for (const { userId } of admins) {
      const remaining = await tx.storeAdmin.count({ where: { userId } });
      if (remaining === 0) {
        await tx.user.update({ where: { id: userId }, data: { role: "user" } });
      }
      await bumpClaimsVersion(tx, userId);
    }
  });
}
