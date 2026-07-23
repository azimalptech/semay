import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { Timestamp } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";
import { smsProvider, smsGatewayUsername, smsGatewayPassword } from "./smsProvider";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface QueuedSms {
  phone: string;
  message: string;
  simIndex: number | null;
  scheduledAt: Timestamp;
}

// Fires once per sendOtp call (see sendOtp.ts, which only writes here — it
// never calls the gateway directly). This is the one place that actually
// talks to the SMS gateway, and it does so exactly at its reserved slot, so
// the real send cadence stays at SEND_INTERVAL_MS no matter how many
// sendOtp calls happened concurrently. timeoutSeconds is set well above
// MAX_QUEUE_DELAY_MS's worst case so a deep backlog doesn't get the instance
// killed mid-sleep.
export const dispatchQueuedSms = onDocumentCreated(
  {
    document: "sms_dispatch_queue/{id}",
    timeoutSeconds: 300,
    secrets: [smsGatewayUsername, smsGatewayPassword],
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data() as QueuedSms;

    const delay = data.scheduledAt.toMillis() - Date.now();
    if (delay > 0) await sleep(delay);

    // The item could have sat in the backlog long enough that its code
    // expired (see sendOtp.ts's OTP_TTL_MS) or got superseded by a fresh
    // code before its slot came up — re-check against the live otp_codes
    // doc rather than trusting the message text baked in at enqueue time.
    const otpSnap = await db.collection("otp_codes").doc(data.phone).get();
    const expiresAt = otpSnap.data()?.expiresAt as Timestamp | undefined;
    if (!expiresAt || expiresAt.toMillis() <= Date.now()) {
      await snap.ref.update({ status: "skipped_expired" });
      return;
    }

    try {
      await smsProvider.sendSms(data.phone, data.message, data.simIndex);
      await snap.ref.update({ status: "sent", sentAt: Timestamp.now() });
    } catch (err) {
      await snap.ref.update({ status: "failed", error: String(err) });
      throw err;
    }
  },
);
