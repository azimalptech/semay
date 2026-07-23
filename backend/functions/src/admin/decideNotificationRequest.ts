import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";
import { broadcastToAllUsers } from "../utils/notify";

interface DecideNotificationRequestRequest {
  requestId: string;
  approve: boolean;
}

// Super Admin's side of requestBroadcastNotification.ts. Approving actually
// sends it (broadcastToAllUsers — same fan-out broadcastNotification uses
// directly) using the requesting store's own name as the push title, since
// the store admin only ever types the message body, not a separate title.
// Rejecting just records the decision — nothing goes out.
export const decideNotificationRequest = onCall<DecideNotificationRequestRequest>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in");
    }
    if (request.auth.token.role !== "superadmin") {
      throw new HttpsError("permission-denied", "Super Admin only");
    }

    const requestId = request.data?.requestId;
    if (typeof requestId !== "string" || !requestId) {
      throw new HttpsError("invalid-argument", "requestId is required");
    }
    const approve = request.data?.approve;
    if (typeof approve !== "boolean") {
      throw new HttpsError("invalid-argument", "approve must be a boolean");
    }

    const ref = db.collection("notificationRequests").doc(requestId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Request not found");
    }
    const data = snap.data()!;
    if (data.status !== "pending") {
      throw new HttpsError("failed-precondition", "Request already decided");
    }

    await ref.update({
      status: approve ? "approved" : "rejected",
      decidedAt: FieldValue.serverTimestamp(),
      decidedBy: request.auth.uid,
    });

    if (!approve) {
      return { success: true };
    }

    const title = (data.storeName as string | undefined) || "SeMay";
    const { sent, failed } = await broadcastToAllUsers(title, data.message as string);
    return { success: true, sent, failed };
  }
);
