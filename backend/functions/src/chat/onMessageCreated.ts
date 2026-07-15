import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { db } from "../utils/firebaseAdmin";
import { sendToTokens } from "../utils/notify";

export const onMessageCreated = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const message = event.data?.data();
    const chatId = event.params.chatId;
    if (!message) return;

    const chatRef = db.collection("chats").doc(chatId);
    const chatSnap = await chatRef.get();
    const chat = chatSnap.data();
    if (!chat) return;

    const isFromUser = message.senderRole === "user";
    const lastMessageText = message.orderId ? "✅ Order accepted" : (message.text as string);

    await chatRef.update({
      lastMessageText,
      lastMessageAt: FieldValue.serverTimestamp(),
      [isFromUser ? "unreadByAdmin" : "unreadByUser"]: FieldValue.increment(1),
    });

    try {
      let tokens: string[] = [];
      if (isFromUser) {
        const storeSnap = await db.collection("stores").doc(chat.storeId).get();
        const adminIds = (storeSnap.data()?.adminIds as string[] | undefined) ?? [];
        const adminDocs = await Promise.all(
          adminIds.map((uid) => db.collection("users").doc(uid).get())
        );
        tokens = adminDocs.flatMap((doc) => (doc.data()?.fcmTokens as string[] | undefined) ?? []);
      } else {
        const userSnap = await db.collection("users").doc(chat.userId).get();
        tokens = (userSnap.data()?.fcmTokens as string[] | undefined) ?? [];
      }

      await sendToTokens(tokens, { title: "New message", body: lastMessageText });
    } catch (err) {
      // Recipient lookup itself failed — still must not affect the chat-doc update above.
      logger.error("onMessageCreated: failed to resolve/notify recipients", err);
    }
  }
);
