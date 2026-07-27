import type { FastifyReply, FastifyRequest } from "fastify";
import type { Role } from "@prisma/client";

/** Role gate. Must run after requireFreshAuth on any route where a demoted
 * user must lose access immediately, not just after their token expires. */
export function requireRole(...roles: Role[]) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (!req.auth || !roles.includes(req.auth.role)) {
      await reply.code(403).send({ error: "FORBIDDEN" });
    }
  };
}

/** Store-admin gate for a :id-style route param — superadmin always passes.
 * Must run after requireFreshAuth so a just-revoked admin is rejected on
 * their very next request instead of riding out their access token's TTL. */
export function requireStoreAdmin(getStoreId: (req: FastifyRequest) => string) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    if (!req.auth) {
      await reply.code(401).send({ error: "UNAUTHENTICATED" });
      return;
    }
    if (req.auth.role === "superadmin") return;
    const storeId = getStoreId(req);
    if (req.auth.role !== "admin" || !req.auth.storeIds.includes(storeId)) {
      await reply.code(403).send({ error: "FORBIDDEN" });
    }
  };
}
