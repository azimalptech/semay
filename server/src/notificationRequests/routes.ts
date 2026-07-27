import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireRole, requireStoreAdmin } from "../auth/authz.js";
import { prisma } from "../db.js";
import { createNotificationRequest, decideNotificationRequest, RequestNotPendingError } from "./service.js";

const createSchema = z.object({ message: z.string().min(1).max(500) });
const decideSchema = z.object({ approve: z.boolean() });
const listQuerySchema = z.object({
  storeId: z.string().optional(),
  status: z.enum(["pending", "approved", "rejected"]).optional(),
});

export async function notificationRequestRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/stores/:storeId/notification-requests",
    {
      preHandler: [
        requireAuth,
        requireFreshAuth,
        requireStoreAdmin((req) => (req.params as { storeId: string }).storeId),
      ],
    },
    async (req, reply) => {
      const { storeId } = req.params as { storeId: string };
      const body = createSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
      const request = await createNotificationRequest(storeId, req.auth!.sub, body.data.message);
      return reply.code(201).send({ request });
    }
  );

  app.get("/notification-requests", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    if (req.auth!.role === "superadmin") {
      const requests = await prisma.notificationRequest.findMany({
        where: {
          ...(query.data.storeId ? { storeId: query.data.storeId } : {}),
          ...(query.data.status ? { status: query.data.status } : {}),
        },
        orderBy: { createdAt: "desc" },
        take: 200,
      });
      return reply.send({ requests });
    }

    if (req.auth!.role === "admin") {
      if (!query.data.storeId || !req.auth!.storeIds.includes(query.data.storeId)) {
        return reply.code(403).send({ error: "FORBIDDEN" });
      }
      const requests = await prisma.notificationRequest.findMany({
        where: {
          storeId: query.data.storeId,
          ...(query.data.status ? { status: query.data.status } : {}),
        },
        orderBy: { createdAt: "desc" },
        take: 200,
      });
      return reply.send({ requests });
    }

    return reply.code(403).send({ error: "FORBIDDEN" });
  });

  app.post(
    "/notification-requests/:id/decide",
    { preHandler: [requireAuth, requireFreshAuth, requireRole("superadmin")] },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const body = decideSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

      try {
        const result = await decideNotificationRequest(id, body.data.approve, req.auth!.sub);
        return reply.send(result);
      } catch (err) {
        if (err instanceof RequestNotPendingError) {
          return reply.code(409).send({ error: "ALREADY_DECIDED" });
        }
        throw err;
      }
    }
  );
}
