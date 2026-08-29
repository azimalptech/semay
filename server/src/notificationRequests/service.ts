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
  // Conditional write, not check-then-update. The read, the status check and
  // the update were three separate awaits with no transaction, so concurrent
  // approvals all passed the guard and each ran broadcastToAllUsers — eight
  // parallel calls pushed the same announcement to every user in the system
  // eight times. A double-click was enough to trigger it; only calls far
  // enough apart hit the 409.
  //
  // Claiming the row as part of the state transition means exactly one caller
  // can move it out of `pending`, and only that caller broadcasts.
  const claimed = await prisma.notificationRequest.updateMany({
    where: { id, status: "pending" },
    data: { status: approve ? "approved" : "rejected", decidedAt: new Date(), decidedBy },
  });
  if (claimed.count === 0) {
    // Either already decided, or it does not exist — findUniqueOrThrow
    // distinguishes them so a missing id still surfaces as a 404, not a 409.
    await prisma.notificationRequest.findUniqueOrThrow({ where: { id } });
    throw new RequestNotPendingError();
  }

  const request = await prisma.notificationRequest.findUniqueOrThrow({ where: { id } });

  if (!approve) return { request, sent: 0, failed: 0 };

  const { sent, failed } = await broadcastToAllUsers(request.storeName, request.message);
  return { request, sent, failed };
}
