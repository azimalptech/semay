import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";
import { sendToTokens } from "../utils/notify";

export const onOrderCreated = onDocumentCreated("orders/{orderId}", async (event) => {
  const order = event.data?.data();
  if (!order) return;

  const superAdminsSnap = await db.collection("users").where("role", "==", "superadmin").get();
  const tokens = superAdminsSnap.docs.flatMap(
    (doc) => (doc.data().fcmTokens as string[] | undefined) ?? []
  );

  await sendToTokens(tokens, {
    title: "New order",
    body: `New order for store ${order.storeId} (x${order.itemQuantity})`,
  });

  await maybeCreditLeaderboard(order);
});

// Every order is created already-"accepted" (see docs/02_DATA_MODEL.md) — so
// crediting the leaderboard right here, in the same trigger, is the whole
// "instant piggy bank" requirement. Only orders at/after the store's own
// configured campaign start count; each store runs an independent campaign
// (see stores/{storeId}.campaignStartAt in docs/02_DATA_MODEL.md) — that's
// also why changing the date is a full recompute (setLeaderboardCampaignStart)
// rather than this trigger being the only place quantities ever change.
async function maybeCreditLeaderboard(order: FirebaseFirestore.DocumentData) {
  const storeSnap = await db.collection("stores").doc(order.storeId).get();
  const campaignStartAt = storeSnap.data()?.campaignStartAt as Timestamp | undefined;
  if (!campaignStartAt) return;

  const createdAt = order.createdAt as Timestamp | undefined;
  if (!createdAt || createdAt.toMillis() < campaignStartAt.toMillis()) return;

  const userSnap = await db.collection("users").doc(order.userId).get();
  const userName = (userSnap.data()?.name as string | undefined) ?? "";

  await db
    .collection("stores")
    .doc(order.storeId)
    .collection("leaderboard")
    .doc(order.userId)
    .set(
      {
        userId: order.userId,
        userName,
        quantity: FieldValue.increment(order.itemQuantity as number),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
}
