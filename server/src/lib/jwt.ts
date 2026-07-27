import jwt from "jsonwebtoken";

import { config } from "../config.js";
import type { Claims } from "../auth/claims.js";

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
    expiresIn: config.ACCESS_TOKEN_TTL_SECONDS,
  });
}

/** Throws jwt.JsonWebTokenError / jwt.TokenExpiredError on invalid/expired tokens. */
export function verifyAccessToken(token: string): AccessTokenPayload {
  return jwt.verify(token, config.JWT_SECRET) as AccessTokenPayload;
}
