import * as logger from "firebase-functions/logger";
import { messaging } from "./firebaseAdmin";

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
