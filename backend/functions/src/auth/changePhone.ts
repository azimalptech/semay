import { onCall, HttpsError } from "firebase-functions/v2/https";
import { db } from "../utils/firebaseAdmin";
import { consumeOtpCode } from "./otpVerification";

interface ChangePhoneRequest {
  phone: string;
  code: string;
}

// Re-verifies a *new* number via the same sendOtp/otp_codes mechanism as
// login before repointing users/{uid}.phone at it — phone is the identity
// key verifyOtp looks up on every future login, so letting it change
// without proof of ownership would let anyone claim any number, and would
// silently orphan the caller's own account on their next login (verifyOtp
// would find no user for the old phone and mint a brand-new one instead).
export const changePhone = onCall<ChangePhoneRequest>(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }

  const { phone, code } = request.data ?? {};
  if (!phone || !code) {
    throw new HttpsError("invalid-argument", "phone and code are required");
  }

  await consumeOtpCode(phone, code);

  const existing = await db.collection("users").where("phone", "==", phone).limit(1).get();
  if (!existing.empty && existing.docs[0].id !== uid) {
    throw new HttpsError("already-exists", "This phone number is already in use");
  }

  await db.collection("users").doc(uid).update({ phone });

  return { success: true };
});
