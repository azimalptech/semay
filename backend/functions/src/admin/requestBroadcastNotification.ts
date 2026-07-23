import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";

interface RequestBroadcastNotificationRequest {
  storeId: string;
  message: string;
}

// Store Admin's side of "request a notification, Super Admin approves it" —
// see decideNotificationRequest.ts for the approve/reject half. Only ever
// creates a pending request; nothing is sent to anyone until a Super Admin
// acts on it.
export const requestBroadcastNotification = onCall<RequestBroadcastNotificationRequest>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in");
    }
    const storeId = request.data?.storeId;
    if (typeof storeId !== "string" || !storeId) {
      throw new HttpsError("invalid-argument", "storeId is required");
    }
    // Must actually admin this store — request.auth.token.storeIds is the
    // same custom claim isStoreAdmin(storeId) checks in firestore.rules.
    const storeIds = (request.auth.token.storeIds as string[] | undefined) ?? [];
    if (request.auth.token.role !== "admin" || !storeIds.includes(storeId)) {
      throw new HttpsError("permission-denied", "Must be an admin of this store");
    }

    const rawMessage = request.data?.message;
    if (typeof rawMessage !== "string") {
      throw new HttpsError("invalid-argument", "message must be a string");
    }
    const message = rawMessage.trim();
    if (!message || message.length > 500) {
      throw new HttpsError("invalid-argument", "message is required and must be under 500 characters");
    }

    const storeSnap = await db.collection("stores").doc(storeId).get();
    if (!storeSnap.exists) {
      throw new HttpsError("not-found", "Store not found");
    }

    const ref = await db.collection("notificationRequests").add({
      storeId,
      storeName: (storeSnap.data()?.name as string | undefined) ?? "",
      requestedBy: request.auth.uid,
      message,
      status: "pending",
      createdAt: FieldValue.serverTimestamp(),
      decidedAt: null,
      decidedBy: null,
    });

    return { success: true, requestId: ref.id };
  }
);
