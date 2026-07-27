import type { NotificationRequest } from "@prisma/client";

import { prisma } from "../db.js";
import { broadcastToAllUsers } from "../notifications/service.js";

export class RequestNotPendingError extends Error {
  constructor() {
    super("Request has already been decided");
  }
}

export async function createNotificationRequest(
  storeId: string,
  requestedBy: string,
  message: string
): Promise<NotificationRequest> {
  const store = await prisma.store.findUniqueOrThrow({ where: { id: storeId }, select: { name: true } });
  return prisma.notificationRequest.create({
    data: { storeId, storeName: store.name, requestedBy, message },
  });
}

/** On approve, broadcasts using the request's own denormalized storeName as
 * the push title — store admins only ever typed a message body, matching the
 * old callable's contract exactly. */
export async function decideNotificationRequest(
  id: string,
  approve: boolean,
  decidedBy: string
): Promise<{ request: NotificationRequest; sent: number; failed: number }> {
  const existing = await prisma.notificationRequest.findUniqueOrThrow({ where: { id } });
  if (existing.status !== "pending") throw new RequestNotPendingError();

  const request = await prisma.notificationRequest.update({
    where: { id },
    data: { status: approve ? "approved" : "rejected", decidedAt: new Date(), decidedBy },
  });

  if (!approve) return { request, sent: 0, failed: 0 };

  const { sent, failed } = await broadcastToAllUsers(request.storeName, request.message);
  return { request, sent, failed };
}
