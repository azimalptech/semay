import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";

interface SetLeaderboardCampaignStartRequest {
  storeId: string;
  startAtMillis: number;
}

// Per-store campaign (see docs/02_DATA_MODEL.md's stores/{storeId}) — each
// store runs its own leaderboard window, independent of every other store's.
export const setLeaderboardCampaignStart = onCall<SetLeaderboardCampaignStartRequest>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in");
    }
    if (request.auth.token.role !== "superadmin") {
      throw new HttpsError("permission-denied", "Super Admin only");
    }

    const storeId = request.data?.storeId;
    if (!storeId || typeof storeId !== "string") {
      throw new HttpsError("invalid-argument", "storeId is required");
    }

    const startAtMillis = request.data?.startAtMillis;
    if (typeof startAtMillis !== "number" || !Number.isFinite(startAtMillis)) {
      throw new HttpsError("invalid-argument", "startAtMillis must be a finite number");
    }
    const campaignStartAt = Timestamp.fromMillis(startAtMillis);

    const storeRef = db.collection("stores").doc(storeId);
    const storeSnap = await storeRef.get();
    if (!storeSnap.exists) {
      throw new HttpsError("not-found", "Store not found");
    }

    await storeRef.update({ campaignStartAt });
    await recomputeStoreLeaderboard(storeId, campaignStartAt);

    return { success: true };
  }
);

// Changing the campaign date isn't a filter on future orders only — orders
// already sitting on/after the new date need folding back in too, and
// entries that no longer qualify need to disappear. Full rebuild of this one
// store's board rather than an incremental patch, so it stays correct
// regardless of how the date moves.
async function recomputeStoreLeaderboard(
  storeId: string,
  campaignStartAt: Timestamp
): Promise<void> {
  const leaderboardRef = db.collection("stores").doc(storeId).collection("leaderboard");
  const leaderboardSnap = await leaderboardRef.get();
  // Chunked — a store with 500+ leaderboard entries would otherwise exceed
  // Firestore's per-batch operation cap and throw mid-recompute, after the
  // campaign date was already updated.
  const existingDocs = leaderboardSnap.docs;
  for (let i = 0; i < existingDocs.length; i += 500) {
    const deleteBatch = db.batch();
    for (const doc of existingDocs.slice(i, i + 500)) deleteBatch.delete(doc.ref);
    await deleteBatch.commit();
  }

  const ordersSnap = await db
    .collection("orders")
    .where("storeId", "==", storeId)
    .where("createdAt", ">=", campaignStartAt)
    .get();

  const totals = new Map<string, number>();
  for (const doc of ordersSnap.docs) {
    const order = doc.data();
    const userId = order.userId as string;
    totals.set(userId, (totals.get(userId) ?? 0) + (order.itemQuantity as number));
  }

  // Resolve display names once per user, not once per order.
  const userIds = [...totals.keys()];
  const userDocs = await Promise.all(userIds.map((uid) => db.collection("users").doc(uid).get()));
  const names = new Map(
    userDocs.map((doc) => [doc.id, (doc.data()?.name as string | undefined) ?? ""])
  );

  const entries = [...totals.entries()];
  for (let i = 0; i < entries.length; i += 500) {
    const batch = db.batch();
    for (const [userId, quantity] of entries.slice(i, i + 500)) {
      batch.set(leaderboardRef.doc(userId), {
        userId,
        userName: names.get(userId) ?? "",
        quantity,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }
}
