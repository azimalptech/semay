import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";
import { db, messaging } from "./firebaseAdmin";

// FCM delivery is never guaranteed and, in this local/demo environment, never
// even reachable (no Messaging emulator, no real project). A failed send must
// never throw and block/roll back the Firestore work a trigger is attached to.
export async function sendToTokens(
  tokens: string[],
  notification: { title: string; body: string },
  data?: Record<string, string>
): Promise<void> {
  if (tokens.length === 0) {
    logger.info("sendToTokens: no fcmTokens to notify");
    return;
  }

  try {
    const response = await messaging.sendEachForMulticast({ tokens, notification, data });
    logger.info(`sendToTokens: sent to ${response.successCount}/${tokens.length} token(s)`);
  } catch (err) {
    logger.error("sendToTokens: FCM send failed", err);
  }
}

// FCM error codes meaning the token itself is dead (app uninstalled, token
// rotated, etc.) — worth pruning so it stops being retried/counted as a
// failure forever. Anything else (rate limits, transient errors) is logged
// but left alone, since the token may still be good. Deliberately excludes
// messaging/invalid-argument: FCM also returns that code when the *message*
// itself is malformed (e.g. an oversized notification body), in which case
// every token in the batch fails with it — treating it as "stale" would
// have pruned every registered token in one bad broadcast.
const STALE_TOKEN_ERROR_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

// Same as sendToTokens, but also removes tokens FCM reports as dead from
// their owner's users/{uid}.fcmTokens — without this, a token from an old
// install/reinstall (this app has been through several during testing)
// lingers forever and shows up as a permanent "failed" in every broadcast.
export async function sendToTokensWithCleanup(
  tokenOwners: Map<string, string>,
  notification: { title: string; body: string }
): Promise<{ sent: number; failed: number }> {
  const tokens = [...tokenOwners.keys()];
  if (tokens.length === 0) return { sent: 0, failed: 0 };

  let sent = 0;
  let failed = 0;
  const staleTokensByUid = new Map<string, string[]>();

  const FCM_BATCH_SIZE = 500;
  for (let i = 0; i < tokens.length; i += FCM_BATCH_SIZE) {
    const batch = tokens.slice(i, i + FCM_BATCH_SIZE);
    try {
      const response = await messaging.sendEachForMulticast({ tokens: batch, notification });
      sent += response.successCount;
      failed += response.failureCount;

      response.responses.forEach((r, idx) => {
        if (r.success) return;
        const code = r.error?.code;
        const token = batch[idx];
        if (code && STALE_TOKEN_ERROR_CODES.has(code)) {
          const uid = tokenOwners.get(token);
          if (!uid) return;
          const list = staleTokensByUid.get(uid) ?? [];
          list.push(token);
          staleTokensByUid.set(uid, list);
        } else {
          logger.warn("sendToTokensWithCleanup: token send failed", {
            code,
            message: r.error?.message,
          });
        }
      });
    } catch (err) {
      // A batch-level throw (vs. a per-token failure in `responses`) means
      // the whole call rejected — e.g. a malformed message. The in-app
      // notification history (writeNotifications) has already been
      // persisted by the time this runs, so this must not throw further:
      // a caller retrying after this partial failure would otherwise
      // duplicate that history for every recipient.
      logger.error("sendToTokensWithCleanup: FCM batch send failed", err);
      failed += batch.length;
    }
  }

  for (const [uid, staleTokens] of staleTokensByUid) {
    await db
      .collection("users")
      .doc(uid)
      .update({ fcmTokens: FieldValue.arrayRemove(...staleTokens) });
  }
  if (staleTokensByUid.size > 0) {
    logger.info(
      `sendToTokensWithCleanup: pruned stale tokens for ${staleTokensByUid.size} user(s)`
    );
  }

  return { sent, failed };
}

// Shared by broadcastNotification (direct Super Admin send) and
// decideNotificationRequest (a store's requested notification, once a Super
// Admin approves it) — same "every user, in-app history + push" fan-out
// either way, just two different paths to authorizing it.
export async function broadcastToAllUsers(
  title: string,
  body: string
): Promise<{ sent: number; failed: number }> {
  const tokenOwners = new Map<string, string>();
  const uids: string[] = [];
  const usersSnap = await db.collection("users").select("fcmTokens").get();
  for (const doc of usersSnap.docs) {
    uids.push(doc.id);
    const docTokens = doc.data().fcmTokens as string[] | undefined;
    if (Array.isArray(docTokens)) {
      for (const token of docTokens) tokenOwners.set(token, doc.id);
    }
  }

  // In-app notification history is independent of whether a device has a
  // push token at all, so this always runs even if there's nothing to send.
  await writeNotifications(uids, { title, body });

  return sendToTokensWithCleanup(tokenOwners, { title, body });
}

// Firestore batched writes cap at 500 operations each.
const BATCH_SIZE = 500;

// Persists an in-app notification (users/{uid}/notifications/{id}) for each
// recipient, independent of FCM delivery — this is what the notifications
// screen and the bell icon's unread badge read from, so it survives even if
// the device was offline/had no token when the push itself went out.
export async function writeNotifications(
  uids: string[],
  notification: { title: string; body: string }
): Promise<void> {
  if (uids.length === 0) return;

  for (let i = 0; i < uids.length; i += BATCH_SIZE) {
    const batch = db.batch();
    for (const uid of uids.slice(i, i + BATCH_SIZE)) {
      const ref = db.collection("users").doc(uid).collection("notifications").doc();
      batch.set(ref, {
        title: notification.title,
        body: notification.body,
        createdAt: FieldValue.serverTimestamp(),
        read: false,
      });
    }
    await batch.commit();
  }
}
