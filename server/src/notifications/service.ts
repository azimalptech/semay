import type { UserNotification } from "@prisma/client";

import { prisma } from "../db.js";
import { sendPushToUsers } from "./push.js";

/** Shared by broadcastNotification and decideNotificationRequest's approve
 * path — same fan-out both used in the old backend (`broadcastToAllUsers`).
 * `sent` counts users who got an in-app notification row; `failed` counts
 * push deliveries FCM reported as failed (per-token, since a user can have
 * multiple devices) — matches the old callable's `{sent, failed}` shape. */
export async function broadcastToAllUsers(
  title: string,
  body: string
): Promise<{ sent: number; failed: number }> {
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
  // notifications above are already durably persisted regardless.
  void sendPushToUsers(userIds, title, body).catch(() => {});
  return { sent: users.length, failed: 0 };
}

export async function listNotifications(
  userId: string,
  opts: { before?: string; limit: number }
): Promise<UserNotification[]> {
  return prisma.userNotification.findMany({
    where: { userId, ...(opts.before ? { id: { lt: BigInt(opts.before) } } : {}) },
    orderBy: { id: "desc" },
    take: opts.limit,
  });
}

export async function markNotificationRead(id: string, userId: string): Promise<void> {
  await prisma.userNotification.updateMany({
    where: { id: BigInt(id), userId, readAt: null },
    data: { readAt: new Date() },
  });
}

export async function markAllNotificationsRead(userId: string): Promise<void> {
  await prisma.userNotification.updateMany({
    where: { userId, readAt: null },
    data: { readAt: new Date() },
  });
}
