import { Prisma } from "@prisma/client";
import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import { AccountDeletedError } from "../auth/claims.js";

/** Single place every unhandled route error funnels through.
 *
 * Two jobs. First, translate the few domain/infrastructure errors that have an
 * obvious HTTP meaning so callers get a stable code instead of a 500. Second,
 * and more importantly: never let an unrecognized error's message reach the
 * client. Prisma exceptions in particular embed table names, column names and
 * fragments of the failing query — a free schema map for anyone probing the API.
 * Those are logged in full server-side and answered with a bare INTERNAL. */
export function registerErrorHandler(app: FastifyInstance): void {
  app.setErrorHandler((err: FastifyError, req: FastifyRequest, reply: FastifyReply) => {
    // A tombstoned account's credentials are dead — see auth/claims.ts.
    if (err instanceof AccountDeletedError) {
      return reply.code(401).send({ error: "ACCOUNT_DELETED" });
    }

    // Body parsing / validation / rate limiting already carry a correct 4xx.
    // Preserve those, but keep our own error-shape contract ({ error }).
    if (err.statusCode && err.statusCode >= 400 && err.statusCode < 500) {
      const code = err.statusCode === 429 ? "RATE_LIMITED" : (err.code ?? "BAD_REQUEST");
      req.log.info({ err, statusCode: err.statusCode }, "client error");
      return reply.code(err.statusCode).send({ error: code });
    }

    if (err instanceof Prisma.PrismaClientKnownRequestError) {
      req.log.error({ err, prismaCode: err.code }, "database error");
      switch (err.code) {
        case "P2002": // unique constraint
          return reply.code(409).send({ error: "CONFLICT" });
        case "P2003": // foreign key constraint
          return reply.code(409).send({ error: "CONSTRAINT_VIOLATION" });
        case "P2025": // findUniqueOrThrow / update on a missing row
          return reply.code(404).send({ error: "NOT_FOUND" });
        default:
          return reply.code(500).send({ error: "INTERNAL" });
      }
    }

    req.log.error({ err }, "unhandled error");
    return reply.code(500).send({ error: "INTERNAL" });
  });

  // Same contract for unmatched routes, so a typo'd path doesn't return
  // Fastify's default HTML-ish payload while every real route returns { error }.
  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: "NOT_FOUND" }));
}
