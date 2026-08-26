import type { User } from "@prisma/client";

import { prisma } from "../db.js";
import { config } from "../config.js";
import { generateOtpCode } from "../lib/crypto.js";

export class OtpCooldownError extends Error {
  constructor(public retryAfterSeconds: number) {
    super("OTP resend cooldown active");
  }
}

export class OtpLockedError extends Error {
  constructor(public lockedUntil: Date) {
    super("Too many attempts — phone temporarily locked");
  }
}

export class OtpInvalidError extends Error {
  constructor(public attemptsRemaining?: number) {
    super("Invalid or expired code");
  }
}

/** Thrown when OTP_TEST_PHONE names an account that is not a plain `user`.
 *
 * The fixed code is a published credential — it lives in an app-store review
 * form and in this repository's docs — so it must never be able to
 * authenticate anything privileged. Without this check the blast radius of the
 * demo login would grow silently the day somebody promoted that number in the
 * admin panel, and nothing would look wrong until it was being used. */
export class TestPhonePrivilegedError extends Error {
  constructor(public role: string) {
    super(`OTP_TEST_PHONE resolves to a "${role}" account; the fixed code only works for "user"`);
    this.name = "TestPhonePrivilegedError";
  }
}

/** True when `phone` is the configured demo account. */
export function isTestPhone(phone: string): boolean {
  return config.OTP_TEST_PHONE !== "" && phone === config.OTP_TEST_PHONE;
}

/**
 * The demo-account path: a fixed code, no SMS, no otp_codes row.
 *
 * Exists because app-store reviewers cannot receive an SMS on a Turkmen
 * number, and a reviewer who cannot log in rejects the build. It is a
 * deliberate authentication bypass and is kept as narrow as it can be: exactly
 * one phone number, exactly one code, and only for an unprivileged account.
 */
async function verifyTestPhone(phone: string, code: string, name?: string): Promise<User> {
  // Compared in constant time — the fixed code is low-entropy and permanent,
  // so it is worth not also leaking it a character at a time.
  const expected = config.OTP_TEST_CODE;
  const supplied = code;
  let mismatch = expected.length ^ supplied.length;
  for (let i = 0; i < Math.max(expected.length, supplied.length); i++) {
    mismatch |= (expected.charCodeAt(i) || 0) ^ (supplied.charCodeAt(i) || 0);
  }
  if (mismatch !== 0) throw new OtpInvalidError();

  return prisma.$transaction(async (tx) => {
    const existing = await tx.user.findUnique({ where: { phone } });
    if (existing) {
      if (existing.role !== "user") throw new TestPhonePrivilegedError(existing.role);
      if (existing.deletedAt) throw new OtpInvalidError();
      return existing;
    }
    // First use creates the account. A name is not demanded the way the real
    // signup flow demands one: a reviewer typing a phone and a code should not
    // be stopped by a form field.
    return tx.user.create({ data: { phone, name: name?.trim() || "Demo Account" } });
  });
}

/** Issues (or re-sends within cooldown rules) a code for `phone`. Caller is
 * responsible for actually dispatching it (dev-mode echo vs real SMS gateway). */
export async function requestOtp(phone: string): Promise<{ code: string }> {
  const now = new Date();
  const existing = await prisma.otpCode.findUnique({ where: { phone } });

  if (existing?.lockedUntil && existing.lockedUntil > now) {
    throw new OtpLockedError(existing.lockedUntil);
  }

  if (existing) {
    const earliestResend = new Date(
      existing.lastSentAt.getTime() + config.OTP_RESEND_COOLDOWN_SECONDS * 1000
    );
    if (earliestResend > now) {
      throw new OtpCooldownError(
        Math.ceil((earliestResend.getTime() - now.getTime()) / 1000)
      );
    }
  }

  const code = generateOtpCode();
  const expiresAt = new Date(now.getTime() + config.OTP_TTL_SECONDS * 1000);

  await prisma.otpCode.upsert({
    where: { phone },
    create: { phone, code, expiresAt, lastSentAt: now, attempts: 0 },
    update: {
      code,
      expiresAt,
      lastSentAt: now,
      attempts: 0,
      lockedUntil: null,
    },
  });

  return { code };
}

/** Removes the pending code for `phone`. Called when the SMS send fails right
 * after requestOtp wrote the row — otherwise the just-set lastSentAt would keep
 * the user in resend cooldown for a code they never received. */
export async function clearOtp(phone: string): Promise<void> {
  await prisma.otpCode.deleteMany({ where: { phone } });
}

/** Verifies a code and consumes the row on success. `SELECT ... FOR UPDATE`
 * serializes concurrent verify attempts against the same phone so the attempts
 * counter (and the lockout it drives) can't be raced. Throws on any failure. */
/** Thrown when a code is correct but the phone has no account yet and the
 * caller supplied no name. Deliberately raised INSIDE verifyOtp's transaction
 * so the whole thing rolls back and the OTP row survives — the client can then
 * collect a name and retry with the SAME code instead of requesting a new one.
 *
 * Checking this after the code is validated (rather than before) is what keeps
 * it from becoming a phone-number enumeration oracle: an attacker without a
 * valid code can't tell a registered number from an unregistered one. */
export class NameRequiredError extends Error {
  constructor() {
    super("A name is required to create an account");
    this.name = "NameRequiredError";
  }
}

/** Verifies the code and, on success, returns the account for `phone` —
 * creating it if this is a first-time signup, in which case `name` is
 * mandatory (see NameRequiredError). Creation lives in the same transaction as
 * the code check so an account can never come into existence without a name. */
export async function verifyOtp(
  phone: string,
  code: string,
  name?: string
): Promise<User> {
  // Checked before touching otp_codes: the demo account never has a row there,
  // because requestOtp never writes one for it.
  if (isTestPhone(phone)) return verifyTestPhone(phone, code, name);

  return prisma.$transaction(async (tx) => {
    const rows = await tx.$queryRaw<
      {
        phone: string;
        code: string;
        expiresAt: Date;
        attempts: number;
        lockedUntil: Date | null;
      }[]
    >`SELECT \`phone\`, \`code\`, \`expiresAt\`, \`attempts\`, \`lockedUntil\`
      FROM \`otp_codes\` WHERE \`phone\` = ${phone} FOR UPDATE`;
    const row = rows[0];
    const now = new Date();

    if (!row) throw new OtpInvalidError();
    if (row.lockedUntil && row.lockedUntil > now) {
      throw new OtpLockedError(row.lockedUntil);
    }
    if (row.expiresAt <= now) throw new OtpInvalidError();

    if (row.code !== code) {
      const attempts = row.attempts + 1;
      const lockedUntil =
        attempts >= config.OTP_MAX_ATTEMPTS
          ? new Date(now.getTime() + config.OTP_LOCKOUT_MINUTES * 60 * 1000)
          : null;
      await tx.otpCode.update({ where: { phone }, data: { attempts, lockedUntil } });
      if (lockedUntil) throw new OtpLockedError(lockedUntil);
      throw new OtpInvalidError(config.OTP_MAX_ATTEMPTS - attempts);
    }

    // Code is correct from here on.
    const existing = await tx.user.findUnique({ where: { phone } });
    const trimmed = name?.trim() ?? "";
    if (!existing && trimmed.length === 0) {
      // Rolls the transaction back, so the OTP row above is NOT deleted and
      // the same code still works on the retry that carries a name.
      throw new NameRequiredError();
    }

    await tx.otpCode.delete({ where: { phone } });

    // findOrCreateUserByPhone's insert-then-reselect race handling isn't needed
    // here: this runs inside the same SELECT ... FOR UPDATE transaction that
    // holds the otp_codes row for this phone, so two concurrent verifies for
    // the same number are already serialised.
    return existing ?? tx.user.create({ data: { phone, name: trimmed } });
  });
}
