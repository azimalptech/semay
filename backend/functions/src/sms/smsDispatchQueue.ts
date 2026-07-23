import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { db } from "../utils/firebaseAdmin";

// The SMS gateway is a physical Android phone (capcom6/android-sms-gateway,
// see smsProvider.ts) — carriers throttle/flag a SIM that fires off SMS in a
// tight burst, so every real send has to be spaced out no matter how many
// sendOtp calls land at once. There's no Cloud Tasks queue provisioned for
// this project (would need gcloud/Console access this environment doesn't
// have), so pacing is done entirely with a Firestore-reserved time slot: each
// call atomically claims "the next available 6-second slot" from a singleton
// cursor doc, and the actual send (a separate Firestore-triggered function,
// see dispatchQueuedSms.ts) sleeps until its own slot before calling the
// gateway. Ordering isn't strictly FIFO under concurrent bursts (two calls
// racing for the transaction can win in either order), but the 6-second
// global cadence is exact.
export const SEND_INTERVAL_MS = 6000;

// Turn on only once the gateway app actually has a second SIM active — this
// alternates simIndex 0/1 per dispatch for wear-leveling across both SIMs
// (not to double throughput; the global cadence stays SEND_INTERVAL_MS
// either way). The android-sms-gateway API's field for this is `simNumber`
// (0-based) on the message payload — verify that still matches your gateway
// app's installed version before flipping this on, since a wrong field name
// just gets silently ignored by most SMS gateway APIs rather than erroring.
export const DUAL_SIM_ENABLED = false;

// A slot scheduled further out than this is a code that will have already
// expired (OTP_TTL_MS in sendOtp.ts) by the time its turn comes up — reject
// the request instead of silently queuing an SMS that will arrive with a
// dead code. Also caps worst-case backlog (~40 items) so a burst can't pin
// down dozens of sleeping function instances indefinitely.
const MAX_QUEUE_DELAY_MS = 4 * 60 * 1000;

const CURSOR_REF = db.collection("sms_dispatch_queue_state").doc("cursor");

export interface DispatchSlot {
  scheduledAt: Timestamp;
  simIndex: number | null;
}

export async function reserveDispatchSlot(): Promise<DispatchSlot> {
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(CURSOR_REF);
    const data = snap.data();
    const prevNextAvailableAt = (data?.nextAvailableAt as Timestamp | undefined)?.toMillis() ?? 0;
    const prevSendCount = (data?.sendCount as number | undefined) ?? 0;

    const now = Date.now();
    const slotMillis = Math.max(now, prevNextAvailableAt);
    if (slotMillis - now > MAX_QUEUE_DELAY_MS) {
      throw new HttpsError(
        "resource-exhausted",
        "Verification code sending is backed up right now — please try again in a few minutes",
      );
    }

    tx.set(
      CURSOR_REF,
      {
        nextAvailableAt: Timestamp.fromMillis(slotMillis + SEND_INTERVAL_MS),
        sendCount: FieldValue.increment(1),
      },
      { merge: true },
    );

    return {
      scheduledAt: Timestamp.fromMillis(slotMillis),
      simIndex: DUAL_SIM_ENABLED ? prevSendCount % 2 : null,
    };
  });
}
