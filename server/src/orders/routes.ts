import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth } from "../auth/middleware.js";
import { ChatForbiddenError, ChatNotFoundError, getChatForParticipant } from "../chats/service.js";
import { prisma } from "../db.js";
import { acceptOrder } from "./service.js";

const acceptOrderSchema = z.object({ itemQuantity: z.number().int().positive().max(9999) });
const listQuerySchema = z.object({ storeId: z.string().optional() });

export async function orderRoutes(app: FastifyInstance): Promise<void> {
  app.post("/chats/:chatId/orders", { preHandler: requireAuth }, async (req, reply) => {
    const { chatId } = req.params as { chatId: string };
    const body = acceptOrderSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    let chat;
    try {
      const result = await getChatForParticipant(chatId, req.auth!);
      if (result.side !== "admin") return reply.code(403).send({ error: "FORBIDDEN" });
      chat = result.chat;
    } catch (err) {
      if (err instanceof ChatNotFoundError) return reply.code(404).send({ error: "NOT_FOUND" });
      if (err instanceof ChatForbiddenError) return reply.code(403).send({ error: "FORBIDDEN" });
      throw err;
    }

    const order = await acceptOrder(chat, req.auth!.sub, body.data.itemQuantity);
    return reply.code(201).send({ order });
  });

  // Reporting only — Super Admin sees everything (optionally scoped with
  // ?storeId=), a store admin only their own store's orders. No plain-user
  // access: customers see their own orders as the chat's system message, not
  // via a dedicated list.
  app.get("/orders", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    if (req.auth!.role === "superadmin") {
      const orders = await prisma.order.findMany({
        where: query.data.storeId ? { storeId: query.data.storeId } : {},
        orderBy: { createdAt: "desc" },
        take: 200,
      });
      return reply.send({ orders });
    }

    if (req.auth!.role === "admin") {
      if (!query.data.storeId || !req.auth!.storeIds.includes(query.data.storeId)) {
        return reply.code(403).send({ error: "FORBIDDEN" });
      }
      const orders = await prisma.order.findMany({
        where: { storeId: query.data.storeId },
        orderBy: { createdAt: "desc" },
        take: 200,
      });
      return reply.send({ orders });
    }

    return reply.code(403).send({ error: "FORBIDDEN" });
  });
}
