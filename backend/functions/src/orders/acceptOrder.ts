import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";

interface AcceptOrderRequest {
  chatId: string;
  itemQuantity: number;
  userPhone: string;
}

export const acceptOrder = onCall<AcceptOrderRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }

  const { chatId, itemQuantity, userPhone } = request.data ?? {};
  if (!chatId || typeof chatId !== "string") {
    throw new HttpsError("invalid-argument", "chatId is required");
  }
  if (!Number.isInteger(itemQuantity) || itemQuantity < 1) {
    throw new HttpsError("invalid-argument", "itemQuantity must be a positive integer");
  }
  if (!userPhone || typeof userPhone !== "string" || !userPhone.trim()) {
    throw new HttpsError("invalid-argument", "userPhone is required");
  }

  const chatSnap = await db.collection("chats").doc(chatId).get();
  const chat = chatSnap.data();
  if (!chat) {
    throw new HttpsError("not-found", "Chat not found");
  }

  const claims = request.auth.token;
  const storeIds = (claims.storeIds as string[] | undefined) ?? [];
  if (claims.role !== "admin" || !storeIds.includes(chat.storeId)) {
    throw new HttpsError("permission-denied", "Not an admin of this chat's store");
  }

  const orderRef = db.collection("orders").doc();
  const messageRef = db.collection("chats").doc(chatId).collection("messages").doc();

  const batch = db.batch();
  batch.set(orderRef, {
    storeId: chat.storeId,
    adminId: request.auth.uid,
    userId: chat.userId,
    chatId,
    itemQuantity,
    userPhone: userPhone.trim(),
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  batch.set(messageRef, {
    senderId: request.auth.uid,
    senderRole: "admin",
    text: "Order accepted ✅",
    mediaUrl: null,
    orderId: orderRef.id,
    createdAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  return { success: true, orderId: orderRef.id };
});
