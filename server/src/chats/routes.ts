import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth } from "../auth/middleware.js";
import { prisma } from "../db.js";
import {
  ChatForbiddenError,
  ChatNotFoundError,
  createOrGetChat,
  getChatForParticipant,
  hideChat,
  listMessages,
  listStoreChats,
  listUserChats,
  markReceipts,
  sendMessage,
  setMuted,
  setTyping,
  type SendMessageInput,
} from "./service.js";

const sendMessageSchema = z
  .object({
    text: z.string().max(4000).optional(),
    mediaUrl: z.string().max(512).optional(),
    mediaType: z.enum(["image", "video"]).optional(),
    orderId: z.string().optional(),
    sharedPostId: z.string().optional(),
    sharedStoryId: z.string().optional(),
    replyToMessageId: z.string().optional(),
    clientKey: z.string().max(64).optional(),
  })
  .refine((v) => Boolean(v.text?.trim() || v.mediaUrl || v.sharedPostId || v.sharedStoryId || v.orderId), {
    message: "Message must have text, media, or a shared reference",
  });

const receiptsSchema = z.object({ status: z.enum(["delivered", "read"]) });
const typingSchema = z.object({ typing: z.boolean() });
const mutedSchema = z.object({ muted: z.boolean() });
const listMessagesQuerySchema = z.object({
  before: z.string().optional(),
  limit: z.coerce.number().int().positive().max(200).default(50),
});

function mapChatError(err: unknown): { code: number; body: { error: string } } | null {
  if (err instanceof ChatNotFoundError) return { code: 404, body: { error: "NOT_FOUND" } };
  if (err instanceof ChatForbiddenError) return { code: 403, body: { error: "FORBIDDEN" } };
  return null;
}

export async function chatRoutes(app: FastifyInstance): Promise<void> {
  app.post("/chats", { preHandler: requireAuth }, async (req, reply) => {
    if (req.auth!.role !== "user") {
      return reply.code(403).send({ error: "FORBIDDEN" });
    }
    const body = z.object({ storeId: z.string().min(1) }).safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const store = await prisma.store.findUnique({ where: { id: body.data.storeId } });
    if (!store) return reply.code(404).send({ error: "NOT_FOUND" });

    const chat = await createOrGetChat(req.auth!.sub, body.data.storeId);
    return reply.code(201).send({ chat });
  });

  app.get("/chats", { preHandler: requireAuth }, async (req, reply) => {
    if (req.auth!.role === "user") {
      const chats = await listUserChats(req.auth!.sub);
      return reply.send({ chats });
    }

    const query = z.object({ storeId: z.string().min(1) }).safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });
    if (req.auth!.role === "admin" && !req.auth!.storeIds.includes(query.data.storeId)) {
      return reply.code(403).send({ error: "FORBIDDEN" });
    }
    const chats = await listStoreChats(query.data.storeId);
    return reply.send({ chats });
  });

  app.get("/chats/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    try {
      const { chat } = await getChatForParticipant(id, req.auth!);
      return reply.send({ chat });
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }
  });

  app.get("/chats/:id/messages", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const query = listMessagesQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    try {
      await getChatForParticipant(id, req.auth!);
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }

    const messages = await listMessages(id, query.data);
    return reply.send({ messages });
  });

  app.post("/chats/:id/messages", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const body = sendMessageSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    try {
      const { chat, side } = await getChatForParticipant(id, req.auth!);
      const message = await sendMessage(chat, side, req.auth!.sub, body.data as SendMessageInput);
      return reply.code(201).send({ message });
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }
  });

  app.post("/chats/:id/receipts", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const body = receiptsSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    try {
      const { chat, side } = await getChatForParticipant(id, req.auth!);
      await markReceipts(chat, side, body.data.status);
      return reply.send({ ok: true });
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }
  });

  app.post("/chats/:id/typing", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const body = typingSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    try {
      const { chat, side } = await getChatForParticipant(id, req.auth!);
      await setTyping(chat, side, body.data.typing);
      return reply.send({ ok: true });
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }
  });

  app.post("/chats/:id/mute", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const body = mutedSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    try {
      const { chat, side } = await getChatForParticipant(id, req.auth!);
      await setMuted(chat, side, body.data.muted);
      return reply.send({ ok: true });
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }
  });

  app.delete("/chats/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    try {
      const { chat, side } = await getChatForParticipant(id, req.auth!);
      await hideChat(chat, side);
      return reply.send({ ok: true });
    } catch (err) {
      const mapped = mapChatError(err);
      if (mapped) return reply.code(mapped.code).send(mapped.body);
      throw err;
    }
  });
}
