import { Prisma, type UserNotification } from "@prisma/client";

import { prisma } from "../db.js";
import { getFcmDisabledReason } from "../lib/firebaseAdmin.js";
import { parseBigIntId } from "../lib/ids.js";
import { isPushEnabled, pushLogger, sendPushToUsers } from "./push.js";

/** Android channel for superadmin broadcasts — created at IMPORTANCE_HIGH by
 * the app's SemayApplication.kt next to the chat one, so a user can silence
 * announcements in system settings without silencing their chats. The id
 * here and there must match. An app that predates the channel falls back to
 * its manifest default (the chat channel), so the server side can ship first.
 * No sound option: announcements keep the system default, only chat messages
 * carry SeMay's own (docs/08 §3b). */
const BROADCAST_PUSH_CHANNEL = "announcements";

/** One shade entry for announcements: a newer broadcast replaces an older
 * unread one (Android `tag`, iOS `thread-id`) instead of stacking — the in-app
 * inbox keeps every one. */
const BROADCAST_PUSH_TAG = "broadcast";

export interface BroadcastResult {
  /** Users who got an in-app inbox row — NOT pushes. Push runs in the
   * background after this returns (see broadcastToAllUsers). */
  sent: number;
  /** Always 0 now that push no longer blocks the request; kept so the old
   * `{sent, failed}` shape (web-admin, notificationRequests) still parses. */
  failed: number;
  /** False when the API has no usable FCM credential: the inbox rows were
   * written but no phone will ring. Surfaced so the panel can say so instead
   * of reporting "Sent: N" for a push that never left the server — which is
   * what a push-less deployment looked like from the admin's chair. */
  pushEnabled: boolean;
  pushDisabledReason?: string;
}

/** One chunk of the fan-out's inbox rows, written straight from the `users`
 * table so a recipient who leaves mid fan-out is handled by the database
 * rather than by a retry.
 *
 * The obvious version — read the ids, then `createMany` them — has two races
 * with `DELETE /users/me`, because the recipient list is read one statement
 * (and, at 100K users, several seconds) earlier:
 *
 *  - A HARD-deleted row makes the whole `createMany` fail with P2003
 *    (`user_notifications.userId` is a real FK, `onDelete: Cascade`), which
 *    `lib/errors.ts` answers with 409 CONSTRAINT_VIOLATION — one deletion and
 *    not one of the 5000 users in that chunk gets the announcement.
 *  - A SOFT delete (the real path: `deleteAccount` scrubs the row and deletes
 *    that user's `user_notifications`) races the other way. Filtering the
 *    recipient list on `deletedAt: null` is not enough on its own: the delete
 *    runs in a transaction whose `deleteMany` gap-locks the index range, so an
 *    insert that starts while it is open BLOCKS and then lands *after* the
 *    commit — leaving one inbox row on an account that was just told its data
 *    was gone, and making `tests/account.deletion.test.ts` red in most full
 *    runs.
 *
 * `INSERT … SELECT` closes both, in one statement, with no retry loop: the
 * SELECT is a locking read inside the insert, so it blocks on that same gap
 * lock and then re-reads — seeing the row hard-deleted (nothing to insert, no
 * FK to violate) or soft-deleted (`deletedAt` now set, excluded). Ids that no
 * longer exist simply select no row. `createdAt` is left to the column default
 * (`DEFAULT CURRENT_TIMESTAMP(3)`, see the init migration).
 *
 * Returns the number of rows actually written, which is what `sent` reports —
 * so the superadmin panel's count is recipients reached, never ids attempted. */
async function insertChunk(ids: string[], title: string, body: string): Promise<number> {
  if (ids.length === 0) return 0;
  return prisma.$executeRaw`
    INSERT INTO user_notifications (userId, title, body)
    SELECT id, ${title}, ${body} FROM users
    WHERE deletedAt IS NULL AND id IN (${Prisma.join(ids)})
  `;
}

/** Shared by broadcastNotification and decideNotificationRequest's approve
 * path — same fan-out both used in the old backend (`broadcastToAllUsers`). */
export async function broadcastToAllUsers(title: string, body: string): Promise<BroadcastResult> {
  // `deletedAt: null`, like every other user-facing query. DELETE /users/me is
  // a scrub, not a row delete (users/service.ts deleteAccount keeps the row so
  // orders keep a valid FK), so an unfiltered fan-out kept writing a
  // user_notifications row per broadcast — forever — for accounts that had been
  // told their data was removed, and reported them in `sent` to the superadmin
  // panel. Their FCM tokens are already gone, so nothing rang; it was pure
  // retention against a deleted account, and an inflated count.
  const users = await prisma.user.findMany({ where: { deletedAt: null }, select: { id: true } });
  const userIds = users.map((u) => u.id);
  // Chunk the insert — a single statement listing 100K ids can blow past
  // MySQL's max_allowed_packet.
  let written = 0;
  for (let i = 0; i < userIds.length; i += 5000) {
    written += await insertChunk(userIds.slice(i, i + 5000), title, body);
  }
  if (written !== userIds.length) {
    // Only reachable when an account was deleted between the list above and
    // its chunk's insert; the announcement still reached everybody else.
    //
    // info, not warn, and deliberately: this is the designed outcome of
    // insertChunk, not a fault. The recipient list is one statement — at 100K
    // users, several seconds — ahead of the inserts, so at any real scale a
    // broadcast that overlaps a single DELETE /users/me lands here. Nothing is
    // lost, nothing is actionable, and nobody should be paged; the count is
    // recorded so `sent` can be reconciled against `listed` after the fact. As
    // a warning it was noise on every busy broadcast — and it is a shared
    // logger, so it also meant a test could not assert that a push path warned
    // about nothing without catching a stranger's deletion.
    pushLogger().info(
      { listed: userIds.length, written },
      "broadcast: recipient(s) deleted mid fan-out, skipped"
    );
  }
  // Push is best-effort and, at scale, slow (hundreds of sequential FCM
  // batches). Fire it in the background so the admin's request returns promptly
  // with the recipient count instead of blocking for the whole fan-out (which
  // would exceed the HTTP timeout well before 100K users). The in-app
  // notifications above are already durably persisted regardless — which is
  // why the outcome goes to the log: it is the only place it can be seen.
  // `type` is what the app keys on to route a tap into the inbox and refresh
  // it; no wakeApp, a broadcast has nothing for a backgrounded app to do.
  void sendPushToUsers(
    userIds,
    title,
    body,
    { type: "broadcast" },
    { channelId: BROADCAST_PUSH_CHANNEL, tag: BROADCAST_PUSH_TAG }
  )
    .then((push) => pushLogger().info({ users: userIds.length, ...push }, "broadcast push done"))
    .catch((err: unknown) => pushLogger().error({ err }, "broadcast push failed"));
  const pushDisabledReason = getFcmDisabledReason();
  return {
    // Rows actually written, not ids attempted — see insertChunk.
    sent: written,
    failed: 0,
    pushEnabled: isPushEnabled(),
    ...(pushDisabledReason !== undefined ? { pushDisabledReason } : {}),
  };
}

export async function listNotifications(
  userId: string,
  opts: { before?: string; limit: number }
): Promise<UserNotification[]> {
  // A malformed cursor is treated as "no cursor" (first page) rather than
  // crashing the request — see lib/ids.ts.
  const before = parseBigIntId(opts.before);
  return prisma.userNotification.findMany({
    where: { userId, ...(before !== undefined ? { id: { lt: before } } : {}) },
    orderBy: { id: "desc" },
    take: opts.limit,
  });
}

/** Returns false when `id` isn't a valid id, so the route can answer 400
 * instead of the 500 a raw BigInt() conversion used to produce. */
export async function markNotificationRead(id: string, userId: string): Promise<boolean> {
  const notificationId = parseBigIntId(id);
  if (notificationId === undefined) return false;
  await prisma.userNotification.updateMany({
    where: { id: notificationId, userId, readAt: null },
    data: { readAt: new Date() },
  });
  return true;
}

export async function markAllNotificationsRead(userId: string): Promise<void> {
  await prisma.userNotification.updateMany({
    where: { userId, readAt: null },
    data: { readAt: new Date() },
  });
}
