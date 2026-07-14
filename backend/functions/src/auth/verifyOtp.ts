import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp, FieldValue } from "firebase-admin/firestore";
import { db, auth } from "../utils/firebaseAdmin";

const MAX_ATTEMPTS = 5;

interface VerifyOtpRequest {
  phone: string;
  code: string;
}

export const verifyOtp = onCall<VerifyOtpRequest>(async (request) => {
  const { phone, code } = request.data ?? {};
  if (!phone || !code) {
    throw new HttpsError("invalid-argument", "phone and code are required");
  }

  const otpRef = db.collection("otp_codes").doc(phone);
  const otpSnap = await otpRef.get();
  if (!otpSnap.exists) {
    throw new HttpsError("not-found", "No verification code was requested for this phone");
  }

  const otp = otpSnap.data()!;
  const expiresAt = otp.expiresAt as Timestamp;
  if (expiresAt.toMillis() < Date.now()) {
    throw new HttpsError("deadline-exceeded", "Verification code has expired");
  }
  if (otp.attempts >= MAX_ATTEMPTS) {
    throw new HttpsError("resource-exhausted", "Too many incorrect attempts");
  }
  if (otp.code !== code) {
    await otpRef.update({ attempts: FieldValue.increment(1) });
    throw new HttpsError("invalid-argument", "Incorrect code");
  }

  await otpRef.delete();

  const usersRef = db.collection("users");
  const existingQuery = await usersRef.where("phone", "==", phone).limit(1).get();

  let uid: string;
  let isNewUser: boolean;
  let role = "user";
  let storeIds: string[] = [];

  if (!existingQuery.empty) {
    const userDoc = existingQuery.docs[0];
    uid = userDoc.id;
    isNewUser = false;
    role = userDoc.data().role ?? "user";
    storeIds = userDoc.data().storeIds ?? [];
  } else {
    const authUser = await auth.createUser({});
    uid = authUser.uid;
    isNewUser = true;
    await usersRef.doc(uid).set({
      phone,
      name: "",
      avatarUrl: "",
      role,
      storeIds,
      fcmTokens: [],
      createdAt: FieldValue.serverTimestamp(),
    });
  }

  await auth.setCustomUserClaims(uid, { role, storeIds });
  const customToken = await auth.createCustomToken(uid, { role, storeIds });

  return { customToken, isNewUser };
});
