import bcrypt from "bcryptjs";

// Password login for the Super Admin web panel, at the owner's explicit request
// — every other account (user, store admin, and originally superadmin too) logs
// in with phone+OTP; see docs/07_MIGRATION.md Phase 8 for why OTP was the
// original design and docs/08_OPERATIONS.md for why this exists instead. Kept in
// its own module so the deviation from "everyone uses OTP" stays a single,
// clearly-named seam rather than scattered inline bcrypt calls.
const BCRYPT_ROUNDS = 12;

export async function hashPassword(plain: string): Promise<string> {
  return bcrypt.hash(plain, BCRYPT_ROUNDS);
}

// A fixed dummy hash so a null-hash comparison still costs a real bcrypt round —
// without this, "phone not found" returns near-instantly while "wrong password"
// takes ~100ms, and that gap is a timing oracle an attacker can use to enumerate
// which phone numbers hold the superadmin role, no password guessing required.
const DUMMY_HASH = bcrypt.hashSync("not-a-real-password-just-for-timing", BCRYPT_ROUNDS);

/** Safe to call with a null hash (unknown phone, or an account with no password
 * set) — always costs one real bcrypt comparison either way, so a caller can't
 * accidentally leak account existence through response timing. */
export async function verifyPassword(plain: string, hash: string | null): Promise<boolean> {
  const matched = await bcrypt.compare(plain, hash ?? DUMMY_HASH);
  return matched && hash !== null;
}
