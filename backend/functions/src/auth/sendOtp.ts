import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { randomInt } from "node:crypto";
import { db } from "../utils/firebaseAdmin";
import { reserveDispatchSlot } from "../sms/smsDispatchQueue";

// First step of every login — opts back out of index.ts's project-wide
// concurrency:1 cap (cpu:1 + concurrency:80) so a burst of simultaneous
// logins is served by warm instances instead of a cold start per request.
// A per-function override only replaces the keys it names, so concurrency
// must be set explicitly here or it would inherit the global 1.

const OTP_TTL_MS = 5 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;

// Same shape the client enforces (auth_service.dart's _isValidPhone) —
// re-checked here because this is an unauthenticated callable with a real
// SMS gateway behind it; without this, "phone" was an arbitrary string used
// directly as a Firestore doc ID (one containing '/' throws; anything else
// creates junk otp_codes docs) and, worse, an open SMS-pumping/toll-fraud
// vector — the only prior throttle was a 60s cooldown per exact phone
// string, which doesn't stop an attacker cycling through numbers.
const PHONE_PATTERN = /^\+993\d{8}$/;

// Coarse global brake on top of the per-phone cooldown: cycling through
// distinct numbers isn't slowed by that cooldown at all, and every send
// costs real money on the SMS gateway. A shared minute-bucket counter is a
// blunt instrument (legitimate traffic queues behind an attacker during a
// burst) but bounds worst-case spend without needing App Check/IP infra.
const GLOBAL_SENDS_PER_MINUTE = 20;

// Set automatically by the Firebase Functions emulator, unset in production.
// sendOtp only echoes the code back in its response under this flag — see
// docs/00_PROJECT_OVERVIEW.md §7 (no real SMS gateway wired up yet).
const isEmulator = process.env.FUNCTIONS_EMULATOR === "true";

function generateCode(): string {
  // Math.random() is not cryptographically secure — a predictable OTP
  // defeats the whole point of the code, even with the attempt lockout.
  return randomInt(100000, 1000000).toString();
}

async function checkGlobalRateLimit(): Promise<void> {
  const bucketId = Math.floor(Date.now() / 60000).toString();
  const bucketRef = db.collection("otp_send_rate_limit").doc(bucketId);
  const exceeded = await db.runTransaction(async (tx) => {
    const snap = await tx.get(bucketRef);
    const count = (snap.data()?.count as number | undefined) ?? 0;
    if (count >= GLOBAL_SENDS_PER_MINUTE) return true;
    tx.set(bucketRef, { count: FieldValue.increment(1) }, { merge: true });
    return false;
  });
  if (exceeded) {
    throw new HttpsError("resource-exhausted", "Too many verification codes requested — try again shortly");
  }
}

interface SendOtpRequest {
  phone: string;
}

export const sendOtp = onCall<SendOtpRequest>({ cpu: 1, concurrency: 80 }, async (request) => {
  const phone = request.data?.phone;
  if (!phone || typeof phone !== "string" || !PHONE_PATTERN.test(phone)) {
    throw new HttpsError("invalid-argument", "phone must be a valid +993 number");
  }

  await checkGlobalRateLimit();

  const otpRef = db.collection("otp_codes").doc(phone);
  const existing = await otpRef.get();
  const now = Date.now();
  const existingData = existing.exists ? existing.data()! : null;

  // A lockout blocks requesting a fresh code too — otherwise it's just a
  // resend away from being pointless.
  const lockedUntil = existingData?.lockedUntil as Timestamp | undefined;
  if (lockedUntil && lockedUntil.toMillis() > now) {
    throw new HttpsError(
      "resource-exhausted",
      "This number is temporarily locked after too many incorrect attempts",
      { lockedUntil: lockedUntil.toMillis() },
    );
  }

  if (existingData) {
    const lastSentAt = existingData.lastSentAt as Timestamp | undefined;
    if (lastSentAt && now - lastSentAt.toMillis() < RESEND_COOLDOWN_MS) {
      throw new HttpsError("resource-exhausted", "Please wait before requesting another code");
    }
  }

  // Resending re-sends the *same* code rather than minting a new one, as
  // long as the previous one hasn't expired yet — only a stale/missing/
  // fully-expired entry gets a fresh code (which also resets attempts).
  const existingExpiresAt = existingData?.expiresAt as Timestamp | undefined;
  const hasLiveCode = existingExpiresAt && existingExpiresAt.toMillis() > now;
  const code = hasLiveCode ? (existingData!.code as string) : generateCode();

  // Reserved before writing otp_codes: if the dispatch backlog is too deep
  // to guarantee delivery before the code expires, reserveDispatchSlot
  // throws — and we want that to fail *before* touching lastSentAt, so a
  // rejected request doesn't burn the caller's resend cooldown for a code
  // that was never actually queued.
  const slot = await reserveDispatchSlot();

  await otpRef.set({
    code,
    expiresAt: Timestamp.fromMillis(now + OTP_TTL_MS),
    lastSentAt: Timestamp.fromMillis(now),
    attempts: hasLiveCode ? (existingData!.attempts as number) : 0,
  });

  // Actual gateway send happens in dispatchQueuedSms.ts, at this slot's
  // scheduled time — decoupled from this callable's response so the client
  // isn't kept waiting on the send-pacing queue.
  await db.collection("sms_dispatch_queue").add({
    phone,
    message: `Your SeMay verification code is ${code}`,
    simIndex: slot.simIndex,
    scheduledAt: slot.scheduledAt,
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
  });

  return { success: true, devCode: isEmulator ? code : null };
});
