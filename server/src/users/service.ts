import { Prisma } from "@prisma/client";

import { prisma } from "../db.js";

/** Registers (or re-points) an FCM token to a user. UNIQUE(token) means a
 * reinstall/relogin reassigns ownership instead of leaving two accounts both
 * claiming a stale token on the same phone.
 *
 * Prisma's upsert is NOT atomic: the app fires token sync from more than one
 * place at launch, so two concurrent requests with the same token can both miss
 * the row and both try to create — the loser then hits P2002 on `token`. We
 * catch that and fall through to an explicit update (the row now exists), which
 * is also exactly the ownership-reassignment path. Idempotent under any number
 * of concurrent calls for the same token. */
export async function registerFcmToken(
  userId: string,
  token: string,
  platform?: string
): Promise<void> {
  try {
    await prisma.userFcmToken.upsert({
      where: { token },
      create: { userId, token, platform },
      update: { userId, platform },
    });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
      await prisma.userFcmToken.update({ where: { token }, data: { userId, platform } });
    } else {
      throw err;
    }
  }
}

/** Thrown when a store owner/admin tries to self-delete. Their stores (and every
 * customer's chats/orders under them) can't just vanish — that's a superadmin
 * operation, not self-service. */
export class AccountDeletionBlockedError extends Error {
  constructor() {
    super("Store owners cannot self-delete their account");
    this.name = "AccountDeletionBlockedError";
  }
}

/** Permanently deletes a regular user's account and all their personal data.
 *
 * Most relations (chats, messages, likes/saves/views, story views, notifications,
 * sessions, FCM tokens, leaderboard entries) `onDelete: Cascade`, so the single
 * user delete removes them. The RESTRICT-ed ones must go first inside the same
 * transaction: the orders they placed and any notification requests. Blocked for
 * admins/superadmins — they own stores (createdBy/storeAdmin) and have accepted
 * orders, whose deletion would cascade other users' data; that path needs the
 * superadmin panel, not a self-service button. */
export async function deleteAccount(userId: string): Promise<void> {
  await prisma.$transaction(async (tx) => {
    const user = await tx.user.findUniqueOrThrow({
      where: { id: userId },
      select: { role: true },
    });
    const ownsStores =
      user.role !== "user" ||
      (await tx.storeAdmin.count({ where: { userId } })) > 0 ||
      (await tx.store.count({ where: { createdById: userId } })) > 0;
    if (ownsStores) throw new AccountDeletionBlockedError();

    // RESTRICT relations — clear before the user delete or the FK blocks it.
    await tx.notificationRequest.deleteMany({ where: { requestedBy: userId } });
    await tx.order.deleteMany({ where: { userId } });
    // Cascades everything else.
    await tx.user.delete({ where: { id: userId } });
  });
}
