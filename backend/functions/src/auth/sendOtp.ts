import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";
import { smsProvider } from "../sms/smsProvider";

const OTP_TTL_MS = 5 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;

function generateCode(): string {
  // TODO: remove this test code before production. For local dev/testing only.
  return "123456";
}

interface SendOtpRequest {
  phone: string;
}

export const sendOtp = onCall<SendOtpRequest>(async (request) => {
  const phone = request.data?.phone;
  if (!phone || typeof phone !== "string") {
    throw new HttpsError("invalid-argument", "phone is required");
  }

  const otpRef = db.collection("otp_codes").doc(phone);
  const existing = await otpRef.get();
  const now = Date.now();

  if (existing.exists) {
    const lastSentAt = existing.data()?.lastSentAt as Timestamp | undefined;
    if (lastSentAt && now - lastSentAt.toMillis() < RESEND_COOLDOWN_MS) {
      throw new HttpsError("resource-exhausted", "Please wait before requesting another code");
    }
  }

  const code = generateCode();
  await otpRef.set({
    code,
    expiresAt: Timestamp.fromMillis(now + OTP_TTL_MS),
    lastSentAt: Timestamp.fromMillis(now),
    attempts: 0,
    verified: false,
  });

  await smsProvider.sendSms(phone, `Your SeMay verification code is ${code}`);

  return { success: true };
});
