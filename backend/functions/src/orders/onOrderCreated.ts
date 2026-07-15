import { onDocumentCreated } from "firebase-functions/v2/firestore";
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
});
