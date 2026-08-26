import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

/** 32 random bytes, base64url. Shown to the operator exactly once at
 * registration — only the hash is stored (see schema.prisma). */
export function generateDeviceToken(): string {
  return randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/** Constant-time string compare that does not leak length either. Both sides
 * are hashed first so the buffers handed to timingSafeEqual are always the
 * same size — it throws on a length mismatch, and branching on that would
 * reintroduce exactly the leak this exists to prevent. */
export function secretEquals(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb);
}
