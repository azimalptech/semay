import jwt from "jsonwebtoken";

import { config } from "../config.js";
import type { Claims } from "../auth/claims.js";

const ALGORITHM = "HS256" as const;

export interface AccessTokenPayload {
  sub: string;
  role: Claims["role"];
  storeIds: string[];
  claimsVersion: number;
}

export function signAccessToken(claims: Claims): string {
  const payload: AccessTokenPayload = {
    sub: claims.userId,
    role: claims.role,
    storeIds: claims.storeIds,
    claimsVersion: claims.claimsVersion,
  };
  return jwt.sign(payload, config.JWT_SECRET, {
    algorithm: ALGORITHM,
    expiresIn: config.ACCESS_TOKEN_TTL_SECONDS,
  });
}

/** Throws jwt.JsonWebTokenError / jwt.TokenExpiredError on invalid/expired tokens.
 *
 * `algorithms` is pinned rather than left to the library's default. This is
 * hardening, not a fix for a live hole: jsonwebtoken v9 already rejects `alg:none`
 * outright (verified), and the secret here is symmetric, so the classic
 * RS256→HS256 confusion doesn't apply either. What an unpinned verify DOES accept
 * is a token signed with a different HMAC variant (HS512), which costs nothing to
 * refuse and keeps the accepted-token set exactly equal to the issued-token set. */
export function verifyAccessToken(token: string): AccessTokenPayload {
  return jwt.verify(token, config.JWT_SECRET, { algorithms: [ALGORITHM] }) as AccessTokenPayload;
}
