import type { UserNotification } from "@prisma/client";

import { prisma } from "../db.js";
import { getFcmDisabledReason } from "../lib/firebaseAdmin.js";
import { parseBigIntId } from "../lib/ids.js";
import { isPushEnabled, pushLogger, sendPushToUsers } from "./push.js";

/** Android channel for superadmin broadcasts — created at IMPORTANCE_HIGH by
 * the app's MainActivity.kt next to the chat one, so a user can silence
 * announcements in system settings without silencing their chats. The id
 * here and there must match. An app that predates the channel falls back to
 * the manifest default (`chat_messages`), so the server side can ship first. */
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

/** Shared by broadcastNotification and decideNotificationRequest's approve
 * path — same fan-out both used in the old backend (`broadcastToAllUsers`). */
export async function broadcastToAllUsers(title: string, body: string): Promise<BroadcastResult> {
  const users = await prisma.user.findMany({ select: { id: true } });
  const userIds = users.map((u) => u.id);
  // Chunk the insert — a single createMany of 100K rows can blow past MySQL's
  // max_allowed_packet.
  for (let i = 0; i < userIds.length; i += 5000) {
    const slice = userIds.slice(i, i + 5000);
    await prisma.userNotification.createMany({
      data: slice.map((id) => ({ userId: id, title, body })),
    });
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
    sent: users.length,
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
