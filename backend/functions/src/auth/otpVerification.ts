import { HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";

const MAX_ATTEMPTS = 5;
const LOCKOUT_MS = 60 * 60 * 1000;

/**
 * Checks phone+code against otp_codes/{phone}, tracking attempts/lockout —
 * shared by verifyOtp (login) and changePhone (in-app re-verification), so
 * both entry points enforce the exact same 5-attempt/1-hour lockout rules.
 * Throws HttpsError on any failure; deletes the doc and returns normally on
 * success — the caller does whatever comes after (mint a token, update a
 * phone field, etc).
 *
 * Runs as a Firestore transaction — plain get()-then-update() let concurrent
 * requests for the same phone all read the same `attempts` value, so none of
 * them ever individually reached MAX_ATTEMPTS (the lockout was brute-force
 * bypassable by firing guesses in parallel), and two concurrent *correct*
 * guesses could both pass the exists+match check before either delete()'d
 * the doc, minting two Auth accounts for one phone. Firestore automatically
 * retries a transaction whose read set changed before commit, so the loser
 * of any race re-reads the *post-write* state (already-incremented attempts,
 * or already-deleted doc) instead of stale data.
 */
export async function consumeOtpCode(phone: string, code: string): Promise<void> {
  const otpRef = db.collection("otp_codes").doc(phone);

  // The transaction closure can retry, so it must stay a pure read+write —
  // throwing straight out of it could otherwise fire the same logical
  // failure more than once. Stash it and throw exactly one time after.
  let failure: HttpsError | null = null;

  await db.runTransaction(async (tx) => {
    failure = null;
    const otpSnap = await tx.get(otpRef);
    if (!otpSnap.exists) {
      failure = new HttpsError("not-found", "No verification code was requested for this phone");
      return;
    }

    const otp = otpSnap.data()!;

    const lockedUntil = otp.lockedUntil as Timestamp | undefined;
    if (lockedUntil && lockedUntil.toMillis() > Date.now()) {
      failure = new HttpsError(
        "resource-exhausted",
        "This number is temporarily locked after too many incorrect attempts",
        { lockedUntil: lockedUntil.toMillis() },
      );
      return;
    }

    const expiresAt = otp.expiresAt as Timestamp;
    if (expiresAt.toMillis() < Date.now()) {
      failure = new HttpsError("deadline-exceeded", "Verification code has expired");
      return;
    }

    if (otp.code !== code) {
      const attempts = (otp.attempts as number) + 1;
      if (attempts >= MAX_ATTEMPTS) {
        const newLockedUntil = Timestamp.fromMillis(Date.now() + LOCKOUT_MS);
        tx.update(otpRef, { attempts, lockedUntil: newLockedUntil });
        failure = new HttpsError(
          "resource-exhausted",
          "Too many incorrect attempts — this number is now locked for an hour",
          { lockedUntil: newLockedUntil.toMillis() },
        );
        return;
      }
      tx.update(otpRef, { attempts });
      failure = new HttpsError("invalid-argument", "Incorrect code", {
        attemptsRemaining: MAX_ATTEMPTS - attempts,
      });
      return;
    }

    tx.delete(otpRef);
  });

  if (failure) throw failure;
}
