import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireStoreAdmin } from "../auth/authz.js";
import { prisma } from "../db.js";
import { parseBigIntId } from "../lib/ids.js";

const createSchema = z.object({
  text: z.string().min(1).max(512),
  position: z.number().int().nonnegative().default(0),
});
const updateSchema = z.object({
  text: z.string().min(1).max(512).optional(),
  position: z.number().int().nonnegative().optional(),
});

async function assertCanManage(
  req: FastifyRequest,
  reply: FastifyReply,
  storeId: string
): Promise<boolean> {
  if (!req.auth) {
    await reply.code(401).send({ error: "UNAUTHENTICATED" });
    return false;
  }
  if (req.auth.role === "superadmin") return true;
  if (req.auth.role === "admin" && req.auth.storeIds.includes(storeId)) return true;
  await reply.code(403).send({ error: "FORBIDDEN" });
  return false;
}

export async function quickReplyRoutes(app: FastifyInstance): Promise<void> {
  app.get(
    "/stores/:storeId/quick-replies",
    {
      preHandler: [
        requireAuth,
        requireFreshAuth,
        requireStoreAdmin((req) => (req.params as { storeId: string }).storeId),
      ],
    },
    async (req, reply) => {
      const { storeId } = req.params as { storeId: string };
      const quickReplies = await prisma.storeQuickReply.findMany({
        where: { storeId },
        orderBy: { position: "asc" },
      });
      return reply.send({ quickReplies });
    }
  );

  app.post(
    "/stores/:storeId/quick-replies",
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
      const quickReply = await prisma.storeQuickReply.create({ data: { storeId, ...body.data } });
      return reply.code(201).send({ quickReply });
    }
  );

  app.patch(
    "/quick-replies/:id",
    { preHandler: [requireAuth, requireFreshAuth] },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const body = updateSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

      const replyId = parseBigIntId(id);
      if (replyId === undefined) return reply.code(400).send({ error: "INVALID_INPUT" });

      const existing = await prisma.storeQuickReply.findUnique({ where: { id: replyId } });
      if (!existing) return reply.code(404).send({ error: "NOT_FOUND" });
      if (!(await assertCanManage(req, reply, existing.storeId))) return;

      const quickReply = await prisma.storeQuickReply.update({
        where: { id: replyId },
        data: body.data,
      });
      return reply.send({ quickReply });
    }
  );

  app.delete(
    "/quick-replies/:id",
    { preHandler: [requireAuth, requireFreshAuth] },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const replyId = parseBigIntId(id);
      if (replyId === undefined) return reply.code(400).send({ error: "INVALID_INPUT" });

      const existing = await prisma.storeQuickReply.findUnique({ where: { id: replyId } });
      if (!existing) return reply.code(404).send({ error: "NOT_FOUND" });
      if (!(await assertCanManage(req, reply, existing.storeId))) return;

      await prisma.storeQuickReply.delete({ where: { id: replyId } });
      return reply.send({ ok: true });
    }
  );
}
