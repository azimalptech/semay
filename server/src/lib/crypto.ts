import { randomBytes, randomInt, createHash } from "node:crypto";

/** Cryptographically-secure 6-digit OTP — Math.random() would be predictable. */
export function generateOtpCode(): string {
  return randomInt(100000, 1000000).toString();
}

/** Opaque refresh-session token, given to the client; only its hash is stored. */
export function generateRefreshToken(): string {
  return randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
