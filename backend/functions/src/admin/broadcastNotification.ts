import { onCall, HttpsError } from "firebase-functions/v2/https";
import { broadcastToAllUsers } from "../utils/notify";

interface BroadcastNotificationRequest {
  title: string;
  body: string;
}

export const broadcastNotification = onCall<BroadcastNotificationRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }
  if (request.auth.token.role !== "superadmin") {
    throw new HttpsError("permission-denied", "Super Admin only");
  }

  const rawTitle = request.data?.title;
  const rawBody = request.data?.body;
  if (typeof rawTitle !== "string" || typeof rawBody !== "string") {
    throw new HttpsError("invalid-argument", "title and body must be strings");
  }
  const title = rawTitle.trim();
  const body = rawBody.trim();
  if (!title || title.length > 100) {
    throw new HttpsError("invalid-argument", "title is required and must be under 100 characters");
  }
  if (!body || body.length > 500) {
    throw new HttpsError("invalid-argument", "body is required and must be under 500 characters");
  }

  const { sent, failed } = await broadcastToAllUsers(title, body);

  return { success: true, sent, failed };
});
