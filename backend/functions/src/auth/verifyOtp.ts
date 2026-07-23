import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { createHash } from "node:crypto";
import { db, auth } from "../utils/firebaseAdmin";
import { consumeOtpCode } from "./otpVerification";

interface VerifyOtpRequest {
  phone: string;
  code: string;
}

// Deterministic per-phone account id: the same number always maps to exactly
// one account, no matter how many devices log in — even simultaneously. This
// is what enforces "1 phone = 1 account". The old flow queried users by phone
// and, if none was found, created a fresh random-uid account — a check-then-
// create race: two devices verifying the same brand-new number at once both
// saw "no account" and each created one, producing duplicate accounts for one
// phone. Here the uid is derived from the phone, so both racing logins compute
// the *same* uid and Firebase Auth's own uid-uniqueness is the lock: one
// createUser wins, the other throws auth/uid-already-exists and reuses it.
//
// Hashed (not the raw phone) so the uid doesn't leak the number, and prefixed
// so it never collides with the random uids of accounts created before this
// scheme (those are still matched by the phone query below).
function uidForPhone(phone: string): string {
  return "u_" + createHash("sha256").update(phone).digest("hex").slice(0, 28);
}

export const verifyOtp = onCall<VerifyOtpRequest>({ cpu: 1, concurrency: 80 }, async (request) => {
  const { phone, code } = request.data ?? {};
  if (!phone || !code) {
    throw new HttpsError("invalid-argument", "phone and code are required");
  }

  await consumeOtpCode(phone, code);

  const usersRef = db.collection("users");

  // Existing account for this phone — covers every prior login from any
  // device, including legacy accounts created with a random uid before the
  // deterministic scheme above. A later (non-simultaneous) login always lands
  // here and reuses the same account.
  const existingQuery = await usersRef.where("phone", "==", phone).limit(1).get();
  if (!existingQuery.empty) {
    const userDoc = existingQuery.docs[0];
    const uid = userDoc.id;
    const role = (userDoc.data().role as string) ?? "user";
    const storeIds = (userDoc.data().storeIds as string[]) ?? [];
    await auth.setCustomUserClaims(uid, { role, storeIds });
    const customToken = await auth.createCustomToken(uid, { role, storeIds });
    // Still route to name entry if they never finished their profile.
    const isNewUser = !(userDoc.data().name as string | undefined);
    return { customToken, isNewUser };
  }

  // Brand-new phone. Create the account idempotently under its deterministic
  // uid so concurrent first-time logins converge instead of duplicating.
  const uid = uidForPhone(phone);
  const role = "user";
  const storeIds: string[] = [];

  let wonCreateRace = true;
  try {
    await auth.createUser({ uid });
  } catch (e) {
    if ((e as { code?: string })?.code !== "auth/uid-already-exists") throw e;
    // A concurrent first login for this same number already created the auth
    // user — reuse the same uid; that other call is writing the user doc.
    wonCreateRace = false;
  }

  if (wonCreateRace) {
    // .create() (not set) so that if the losing racer somehow reaches here too
    // it can't clobber the winner's doc — it's write-once seed data. A code-6
    // (ALREADY_EXISTS) just means the doc is already there (e.g. a function
    // retry), which is fine to ignore.
    try {
      await usersRef.doc(uid).create({
        phone,
        name: "",
        avatarUrl: "",
        role,
        storeIds,
        fcmTokens: [],
        createdAt: FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if ((e as { code?: number })?.code !== 6) throw e;
    }
  }

  await auth.setCustomUserClaims(uid, { role, storeIds });
  const customToken = await auth.createCustomToken(uid, { role, storeIds });
  return { customToken, isNewUser: true };
});
