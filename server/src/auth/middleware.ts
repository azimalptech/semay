import type { FastifyReply, FastifyRequest } from "fastify";

import { verifyAccessToken, type AccessTokenPayload } from "../lib/jwt.js";
import { getClaimsForUser } from "./claims.js";
import { isUserTokenRevoked } from "./revocation.js";

declare module "fastify" {
  interface FastifyRequest {
    auth?: AccessTokenPayload;
  }
}

function extractToken(req: FastifyRequest): string | undefined {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return undefined;
  return header.slice("Bearer ".length);
}

/** Fast path: local JWT signature + expiry check only, no DB hit. Use on every
 * authenticated route. */
export async function requireAuth(
  req: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const token = extractToken(req);
  if (!token) {
    return reply.code(401).send({ error: "UNAUTHENTICATED" });
  }
  let payload: AccessTokenPayload;
  try {
    payload = verifyAccessToken(token);
  } catch {
    return reply.code(401).send({ error: "UNAUTHENTICATED" });
  }
  // A deleted account's outstanding access token must stop working immediately,
  // not at its natural expiry — see revocation.ts.
  if (isUserTokenRevoked(payload.sub)) {
    return reply.code(401).send({ error: "UNAUTHENTICATED" });
  }
  req.auth = payload;
}

/** Slow path: re-derives claims from the DB and compares claims_version against
 * the token's — a stale token (e.g. after a store-admin change) fails here with
 * CLAIMS_STALE instead of silently granting/denying on outdated role/storeIds.
 * Use on sensitive routes (store-admin writes, superadmin actions); the client
 * refreshes once and retries on this code. Must run after requireAuth. */
export async function requireFreshAuth(
  req: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  if (!req.auth) {
    return reply.code(401).send({ error: "UNAUTHENTICATED" });
  }
  const claims = await getClaimsForUser(req.auth.sub);
  if (claims.claimsVersion !== req.auth.claimsVersion) {
    return reply.code(401).send({ error: "CLAIMS_STALE" });
  }
  req.auth = {
    sub: claims.userId,
    role: claims.role,
    storeIds: claims.storeIds,
    claimsVersion: claims.claimsVersion,
  };
}
