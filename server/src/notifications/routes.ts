import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireRole } from "../auth/authz.js";
import {
  broadcastToAllUsers,
  listNotifications,
  markAllNotificationsRead,
  markNotificationRead,
} from "./service.js";

const listQuerySchema = z.object({
  before: z.string().optional(),
  limit: z.coerce.number().int().positive().max(100).default(30),
});

const broadcastSchema = z.object({
  title: z.string().min(1).max(100),
  body: z.string().min(1).max(500),
});

export async function notificationRoutes(app: FastifyInstance): Promise<void> {
  app.get("/notifications", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });
    const notifications = await listNotifications(req.auth!.sub, query.data);
    return reply.send({ notifications });
  });

  app.post("/notifications/:id/read", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const ok = await markNotificationRead(id, req.auth!.sub);
    if (!ok) return reply.code(400).send({ error: "INVALID_INPUT" });
    return reply.send({ ok: true });
  });

  app.post("/notifications/read-all", { preHandler: requireAuth }, async (req, reply) => {
    await markAllNotificationsRead(req.auth!.sub);
    return reply.send({ ok: true });
  });

  app.post(
    "/notifications/broadcast",
    { preHandler: [requireAuth, requireFreshAuth, requireRole("superadmin")] },
    async (req, reply) => {
      const body = broadcastSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
      const result = await broadcastToAllUsers(body.data.title, body.data.body);
      return reply.send(result);
    }
  );
}
