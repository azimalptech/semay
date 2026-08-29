import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireStoreAdmin } from "../auth/authz.js";
import { prisma } from "../db.js";
import {
  annotateWithUserFlags,
  applyInteractionBatch,
  createPost,
  deletePostCascade,
  setLike,
  setSave,
  updateCaption,
} from "./service.js";

const mediaItemSchema = z.object({
  url: z.string().min(1).max(512),
  // Bounded to INT_MAX: `position` is a 32-bit column, and an unbounded value
  // that passes schema validation reaches Prisma and throws a validation error
  // the error mapper does not recognise, surfacing as a 500 on client input.
  position: z.number().int().nonnegative().max(2147483647),
  thumbnailUrl: z.string().max(512).optional(),
});

const createPostSchema = z.object({
  type: z.enum(["image", "carousel", "reel"]),
  caption: z.string().max(2000).default(""),
  price: z.number().nonnegative().optional(),
  thumbnailUrl: z.string().max(512).optional(),
  media: z.array(mediaItemSchema).min(1),
});

const listQuerySchema = z.object({
  type: z.enum(["image", "carousel", "reel"]).optional(),
  limit: z.coerce.number().int().positive().max(100).default(20),
  // Bounded for the same reason as `position` — a huge offset is meaningless
  // as a page cursor and reaches the driver as an out-of-range integer.
  offset: z.coerce.number().int().nonnegative().max(1000000).default(0),
});

const updateCaptionSchema = z.object({ caption: z.string().max(2000) });

// Batched view/send/share increments from the mobile interaction buffer. Each
// item is one post; the client already deduped per its 30-minute re-count
// window, so these are plain increments, not once-ever records.
// Per-field cap of 1, deliberately — NOT a round "big enough" number.
// interaction_buffer.dart stores at most one row per (post, kind) per 30-minute
// window and aggregates by counting those rows, so an honest client sends
// exactly 0 or 1 for each field. The previous cap of 100000 let any user turn a
// single request into 100,000,000 fabricated views/shares (1000 items x 100000),
// with no server-side dedup to catch it since dedup lives entirely client-side.
// Clamping to what a real client can actually produce closes the amplification
// while being impossible for a legitimate flush to hit.
const MAX_PER_FLUSH = 1;

const interactionBatchSchema = z.object({
  items: z
    .array(
      z.object({
        postId: z.string().min(1).max(64),
        views: z.number().int().nonnegative().max(MAX_PER_FLUSH).optional(),
        sent: z.number().int().nonnegative().max(MAX_PER_FLUSH).optional(),
        shares: z.number().int().nonnegative().max(MAX_PER_FLUSH).optional(),
      })
    )
    .max(1000),
});

/** DELETE /posts/:id needs the post's storeId (not a URL param) to check
 * store-admin membership, so it can't use requireStoreAdmin's synchronous
 * getStoreId(req) shape directly — this does the same check inline. */
async function assertCanManagePost(
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

export async function postRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    "/stores/:storeId/posts",
    {
      preHandler: [
        requireAuth,
        requireFreshAuth,
        requireStoreAdmin((req) => (req.params as { storeId: string }).storeId),
      ],
    },
    async (req, reply) => {
      const { storeId } = req.params as { storeId: string };
      const body = createPostSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

      const post = await createPost({ storeId, ...body.data });
      return reply.code(201).send({ post });
    }
  );

  app.get("/stores/:storeId/posts", { preHandler: requireAuth }, async (req, reply) => {
    const { storeId } = req.params as { storeId: string };
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const rows = await prisma.post.findMany({
      where: { storeId, ...(query.data.type ? { type: query.data.type } : {}) },
      orderBy: { createdAt: "desc" },
      take: query.data.limit,
      skip: query.data.offset,
      include: { media: { orderBy: { position: "asc" } } },
    });
    const posts = await annotateWithUserFlags(rows, req.auth!.sub);
    return reply.send({ posts });
  });

  app.get("/feed", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const rows = await prisma.post.findMany({
      where: { type: { in: ["image", "carousel"] } },
      orderBy: { createdAt: "desc" },
      take: query.data.limit,
      skip: query.data.offset,
      include: { media: { orderBy: { position: "asc" } } },
    });
    const posts = await annotateWithUserFlags(rows, req.auth!.sub);
    return reply.send({ posts });
  });

  app.get("/reels", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const rows = await prisma.post.findMany({
      where: { type: "reel" },
      orderBy: { createdAt: "desc" },
      take: query.data.limit,
      skip: query.data.offset,
      include: { media: { orderBy: { position: "asc" } } },
    });
    const posts = await annotateWithUserFlags(rows, req.auth!.sub);
    return reply.send({ posts });
  });

  app.get("/posts/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const post = await prisma.post.findUnique({
      where: { id },
      include: { media: { orderBy: { position: "asc" } } },
    });
    if (!post) return reply.code(404).send({ error: "NOT_FOUND" });
    const [annotated] = await annotateWithUserFlags([post], req.auth!.sub);
    return reply.send({ post: annotated });
  });

  // Caption-only edit (edit_caption_dialog.dart) — Instagram scopes post
  // editing to the caption, media stays as uploaded. Owner store-admin only,
  // same authz shape as DELETE below (storeId resolved from the post, not a
  // URL param).
  app.patch(
    "/posts/:id",
    { preHandler: [requireAuth, requireFreshAuth] },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const body = updateCaptionSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

      const post = await prisma.post.findUnique({ where: { id }, select: { storeId: true } });
      if (!post) return reply.code(404).send({ error: "NOT_FOUND" });
      if (!(await assertCanManagePost(req, reply, post.storeId))) return;

      const updated = await updateCaption(id, body.data.caption);
      return reply.send({ post: updated });
    }
  );

  app.delete(
    "/posts/:id",
    { preHandler: [requireAuth, requireFreshAuth] },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const post = await prisma.post.findUnique({ where: { id }, select: { storeId: true } });
      if (!post) return reply.code(404).send({ error: "NOT_FOUND" });
      if (!(await assertCanManagePost(req, reply, post.storeId))) return;

      await deletePostCascade(id);
      return reply.send({ ok: true });
    }
  );

  app.post("/posts/:id/like", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    await setLike(id, req.auth!.sub, true);
    return reply.send({ ok: true });
  });

  app.delete("/posts/:id/like", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    await setLike(id, req.auth!.sub, false);
    return reply.send({ ok: true });
  });

  app.post("/posts/:id/save", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    await setSave(id, req.auth!.sub, true);
    return reply.send({ ok: true });
  });

  app.delete("/posts/:id/save", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    await setSave(id, req.auth!.sub, false);
    return reply.send({ ok: true });
  });

  // Batched view/send/share flush from the mobile interaction buffer (every
  // ~30 min / on background). Replaces the old per-tap POST /posts/:id/view|
  // sent|share once-ever endpoints — the dedup + re-count window now live on
  // the client (see mobile/lib/core/interaction_buffer.dart).
  app.post("/posts/interactions", { preHandler: requireAuth }, async (req, reply) => {
    const body = interactionBatchSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
    await applyInteractionBatch(body.data.items);
    return reply.send({ ok: true });
  });
}
