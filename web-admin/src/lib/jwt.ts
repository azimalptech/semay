import "server-only";
import jwt from "jsonwebtoken";

// Mirrors server/src/lib/jwt.ts's AccessTokenPayload/verifyAccessToken — this
// app only ever verifies tokens server/ issues, it never signs its own, so it
// only needs the verify half. Requires JWT_SECRET to match server/.env exactly.
export interface AccessTokenPayload {
  sub: string;
  role: "user" | "admin" | "superadmin";
  storeIds: string[];
  claimsVersion: number;
}

function getSecret(): string {
  const secret = process.env.JWT_SECRET;
  if (!secret) {
    throw new Error("JWT_SECRET is not set (must match server/.env's JWT_SECRET)");
  }
  return secret;
}

/** Throws jwt.JsonWebTokenError / jwt.TokenExpiredError on invalid/expired tokens. */
export function verifyAccessToken(token: string): AccessTokenPayload {
  return jwt.verify(token, getSecret()) as unknown as AccessTokenPayload;
}
