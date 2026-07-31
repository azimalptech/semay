import { randomBytes } from "node:crypto";

import { Prisma } from "@prisma/client";

import { revokeUserTokens } from "../auth/revocation.js";
import { prisma } from "../db.js";
import { deleteMediaByUrl } from "../media/storage.js";
import { publish } from "../realtime/bus.js";

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

/** Thrown when the account is already tombstoned — a replayed delete request. */
export class AccountAlreadyDeletedError extends Error {
  constructor() {
    super("Account is already deleted");
    this.name = "AccountAlreadyDeletedError";
  }
}

/** Deletes a regular user's account by **anonymizing in place**, not removing
 * the row.
 *
 * Orders must survive: a store's sales history and its accepted-order records
 * are business data belonging to the store, not the customer, and `orders.userId`
 * is a RESTRICT FK. So the row stays as a tombstone and everything personal is
 * either scrubbed or hard-deleted:
 *
 * - Scrubbed on the row: `phone` → a `del_…` sentinel (frees the real number for
 *   a genuine fresh signup, and keeps the UNIQUE index satisfied), `name`,
 *   `avatarUrl`, `activeChatId`. `deletedAt` is stamped.
 * - Scrubbed off orders: `userPhone` is a denormalized copy of the number, so it
 *   has to be rewritten too or deletion leaks the very thing it removes.
 * - Hard-deleted: chats (cascading their messages), likes/saves/views/sent/
 *   shares, story views + seen markers, notifications, notification requests,
 *   sessions, FCM tokens, and leaderboard entries — the last so a deleted user
 *   stops appearing on a *public* surface, while their orders stay in the
 *   store's private records.
 * - `claimsVersion` is bumped and every session dropped, so outstanding refresh
 *   tokens dead-end immediately and any `requireFreshAuth` route rejects the
 *   still-unexpired access token.
 *
 * Blocked for admins/superadmins: they own stores and have accepted orders whose
 * removal would cascade *other* users' data. That path needs the superadmin
 * panel, not a self-service button. */
export async function deleteAccount(userId: string): Promise<void> {
  // Captured inside the transaction, used after it commits — clearing the column
  // is not enough on its own, the uploaded file has to leave the disk too.
  let avatarUrl = "";

  await prisma.$transaction(async (tx) => {
    const user = await tx.user.findUniqueOrThrow({
      where: { id: userId },
      select: { role: true, deletedAt: true, avatarUrl: true },
    });
    if (user.deletedAt) throw new AccountAlreadyDeletedError();
    avatarUrl = user.avatarUrl;

    const ownsStores =
      user.role !== "user" ||
      (await tx.storeAdmin.count({ where: { userId } })) > 0 ||
      (await tx.store.count({ where: { createdById: userId } })) > 0;
    if (ownsStores) throw new AccountDeletionBlockedError();

    // 12 hex chars keeps the sentinel inside phone's VarChar(20) while making a
    // collision between two tombstones effectively impossible.
    const tombstone = `del_${randomBytes(6).toString("hex")}`;

    // Chats cascade their own messages; deleting the chat row is enough.
    await tx.chat.deleteMany({ where: { userId } });
    await tx.notificationRequest.deleteMany({ where: { requestedBy: userId } });
    await tx.storeLeaderboard.deleteMany({ where: { userId } });
    await tx.userNotification.deleteMany({ where: { userId } });
    await tx.session.deleteMany({ where: { userId } });
    await tx.userFcmToken.deleteMany({ where: { userId } });
    await tx.userStorySeen.deleteMany({ where: { userId } });
    await tx.storyView.deleteMany({ where: { userId } });
    await tx.postLike.deleteMany({ where: { userId } });
    await tx.postSave.deleteMany({ where: { userId } });
    await tx.postView.deleteMany({ where: { userId } });
    await tx.postSent.deleteMany({ where: { userId } });
    await tx.postShare.deleteMany({ where: { userId } });

    // Denormalized phone copy on retained orders — scrub or deletion leaks it.
    await tx.order.updateMany({ where: { userId }, data: { userPhone: tombstone } });

    await tx.user.update({
      where: { id: userId },
      data: {
        phone: tombstone,
        name: "",
        avatarUrl: "",
        activeChatId: null,
        deletedAt: new Date(),
        claimsVersion: { increment: 1 },
      },
    });
  });

  // After commit, never inside the transaction — a rolled-back delete must not
  // leave the user locked out of a still-live account.
  revokeUserTokens(userId);
  // Drop any WebSocket still open for them; otherwise a live socket would keep
  // streaming a deleted account's channels until it happened to disconnect.
  publish(`user:${userId}:claims`, { type: "remove", id: userId });
  // Their profile photo is personal data — "deleted" has to mean the bytes are
  // gone, not just the column that pointed at them.
  await deleteMediaByUrl(avatarUrl);
}
