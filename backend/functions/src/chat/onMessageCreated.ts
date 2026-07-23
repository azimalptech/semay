import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { db } from "../utils/firebaseAdmin";
import { sendToTokens } from "../utils/notify";

// The busiest trigger in the app (fires per chat message), so it explicitly
// opts back out of index.ts's project-wide concurrency:1 cap: cpu:1 +
// concurrency:80 lets a single warm instance fan out up to 80 simultaneous
// messages instead of cold-starting a new instance per message when lots of
// people chat at once. (A per-function override only replaces the keys it
// sets — without naming concurrency here it would inherit the global 1.)
export const onMessageCreated = onDocumentCreated(
  { document: "chats/{chatId}/messages/{messageId}", cpu: 1, concurrency: 80 },
  async (event) => {
    const message = event.data?.data();
    const chatId = event.params.chatId;
    const messageId = event.params.messageId;
    if (!message) return;

    const chatRef = db.collection("chats").doc(chatId);
    const chatSnap = await chatRef.get();
    const chat = chatSnap.data();
    if (!chat) return;

    const isFromUser = message.senderRole === "user";
    const lastMessageText = message.orderId
      ? "✅ Order accepted"
      : message.text
        ? (message.text as string)
        : message.mediaType === "video"
          ? "🎥 Video"
          : message.mediaType === "image"
            ? "📷 Photo"
            : "";

    // The single-recipient "message to the customer" case can cleanly skip
    // the increment when that customer already has this exact chat open
    // (their activeChatId, set by ChatThreadScreen — see chat_service.dart's
    // setActiveChat) — avoiding even a brief flash of an unread badge they're
    // already looking at. The admin side can't get the same treatment: a
    // store's adminIds can be several people sharing one unreadByAdmin
    // counter, so "one of them has it open" doesn't mean all of them do —
    // same granularity the existing typingAdminAt/unreadByAdmin fields
    // already accept.
    let skipUserUnreadIncrement = false;
    if (!isFromUser) {
      const userSnap = await db.collection("users").doc(chat.userId as string).get();
      skipUserUnreadIncrement = userSnap.data()?.activeChatId === chatId;
    }

    const chatUpdate: FirebaseFirestore.UpdateData<FirebaseFirestore.DocumentData> = {
      lastMessageText,
      lastMessageAt: FieldValue.serverTimestamp(),
    };
    if (isFromUser) {
      chatUpdate.unreadByAdmin = FieldValue.increment(1);
    } else if (!skipUserUnreadIncrement) {
      chatUpdate.unreadByUser = FieldValue.increment(1);
    }
    await chatRef.update(chatUpdate);

    try {
      let recipientUids: string[] = [];
      let title = "New message";
      if (isFromUser) {
        const storeSnap = await db.collection("stores").doc(chat.storeId).get();
        recipientUids = (storeSnap.data()?.adminIds as string[] | undefined) ?? [];
      } else {
        recipientUids = [chat.userId as string];
        const storeSnap = await db.collection("stores").doc(chat.storeId).get();
        const storeName = storeSnap.data()?.name as string | undefined;
        if (storeName) title = `${storeName} sent you a message`;
      }

      // Muting (chats/{chatId}.mutedByUser/mutedByAdmin, set from the chat
      // thread's own mute toggle) always suppresses the push outright.
      // Beyond that, a recipient whose activeChatId is *this* chat is
      // looking straight at it right now — pushing a notification for a
      // message they can already see on screen is exactly the "silently
      // stays in my chatroom instead of behaving like a normal notification"
      // complaint this was built to fix, just inverted: push only when the
      // chat is NOT the thing currently in front of them.
      const isMuted = isFromUser ? chat.mutedByAdmin === true : chat.mutedByUser === true;
      let tokens: string[] = [];
      if (!isMuted) {
        const recipientDocs = await Promise.all(
          recipientUids.map((uid) => db.collection("users").doc(uid).get())
        );
        tokens = recipientDocs
          .filter((doc) => doc.data()?.activeChatId !== chatId)
          .flatMap((doc) => (doc.data()?.fcmTokens as string[] | undefined) ?? []);
      }

      // Chat messages surface through the chat itself (unreadByUser/
      // unreadByAdmin on the chat doc, read by the Chat tab's own badge) —
      // not through the general Notifications screen too. Deliberately no
      // writeNotifications() call here, unlike broadcastNotification/
      // onOrderCreated: those are one-off system events with nowhere else to
      // show up, but a chat message duplicated into both places is exactly
      // the "sent notifications and messages are different" split every
      // normal chat app keeps. The FCM push below still fires either way —
      // that's the backgrounded/closed-app alert, independent of this.
      //
      // The data payload (chatId/messageId, no notification-only info) is
      // what the client's background/foreground FCM handler uses to mark
      // this exact message deliveredAt — see
      // notification_service.dart's _markMessageDelivered — giving a real
      // "reached the recipient's device" signal independent of whether they
      // ever open the thread, same as the double-gray-check semantics this
      // was modeled on.
      await sendToTokens(tokens, { title, body: lastMessageText }, { chatId, messageId });
    } catch (err) {
      // Recipient lookup itself failed — still must not affect the chat-doc update above.
      logger.error("onMessageCreated: failed to resolve/notify recipients", err);
    }
  }
);
