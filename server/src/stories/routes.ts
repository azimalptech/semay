import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireStoreAdmin } from "../auth/authz.js";
import { prisma } from "../db.js";
import { createStory, getStoryRings, markStoreSeen, recordStoryView } from "./service.js";

const createStorySchema = z.object({
  mediaUrl: z.string().min(1).max(512),
  mediaType: z.enum(["image", "video"]),
});

async function assertCanManageStory(
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

export async function storyRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/stores/:storeId/stories",
    {
      preHandler: [
        requireAuth,
        requireFreshAuth,
        requireStoreAdmin((req) => (req.params as { storeId: string }).storeId),
      ],
    },
    async (req, reply) => {
      const { storeId } = req.params as { storeId: string };
      const body = createStorySchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

      const story = await createStory(storeId, body.data.mediaUrl, body.data.mediaType);
      return reply.code(201).send({ story });
    }
  );

  // Active (unexpired) stories across all stores — client groups by store for the story rings.
  app.get("/stories/active", { preHandler: requireAuth }, async (_req, reply) => {
    const stories = await prisma.story.findMany({
      where: { expiresAt: { gt: new Date() } },
      orderBy: { createdAt: "asc" },
    });
    return reply.send({ stories });
  });

  // Purpose-built for the home story bar — one ready-to-render ring per store,
  // seen/own state computed server-side (replaces the client's 3-listener
  // stitching; see stories/service.ts getStoryRings).
  app.get("/stories/rings", { preHandler: requireAuth }, async (req, reply) => {
    const rings = await getStoryRings(req.auth!.sub, req.auth!.storeIds);
    return reply.send({ rings });
  });

  app.get("/stores/:storeId/stories", { preHandler: requireAuth }, async (req, reply) => {
    const { storeId } = req.params as { storeId: string };
    const stories = await prisma.story.findMany({
      where: { storeId, expiresAt: { gt: new Date() } },
      orderBy: { createdAt: "asc" },
    });
    return reply.send({ stories });
  });

  app.delete(
    "/stories/:id",
    { preHandler: [requireAuth, requireFreshAuth] },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const story = await prisma.story.findUnique({ where: { id }, select: { storeId: true } });
      if (!story) return reply.code(404).send({ error: "NOT_FOUND" });
      if (!(await assertCanManageStory(req, reply, story.storeId))) return;

      await prisma.story.delete({ where: { id } });
      return reply.send({ ok: true });
    }
  );

  app.post("/stores/:storeId/story-seen", { preHandler: requireAuth }, async (req, reply) => {
    const { storeId } = req.params as { storeId: string };
    await markStoreSeen(storeId, req.auth!.sub);
    return reply.send({ ok: true });
  });

  app.post("/stories/:id/view", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    await recordStoryView(id, req.auth!.sub);
    return reply.send({ ok: true });
  });

  // "Seen by N" shown to the owning store's admin in the story viewer footer.
  app.get("/stories/:id/views", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const count = await prisma.storyView.count({ where: { storyId: id } });
    return reply.send({ count });
  });
}
