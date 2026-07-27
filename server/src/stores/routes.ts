import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireRole, requireStoreAdmin } from "../auth/authz.js";
import { prisma } from "../db.js";
import { publish } from "../realtime/bus.js";
import { deleteStoreCascade, setStoreAdmin } from "./service.js";

const createStoreSchema = z.object({
  name: z.string().min(1).max(120),
  tagline: z.string().max(255).optional(),
  phone: z.string().max(20).optional(),
  address: z.string().max(255).optional(),
  avatarUrl: z.string().max(512).optional(),
  coverUrl: z.string().max(512).optional(),
});

// Store-admin self-service edit (edit_store_screen.dart) — the fields a store
// admin may change on their own store. NOT `active` or `leaderboardOrder`
// (superadmin-only concerns).
const updateStoreSchema = z.object({
  name: z.string().min(1).max(120).optional(),
  tagline: z.string().max(255).optional(),
  phone: z.string().max(20).optional(),
  address: z.string().max(255).optional(),
  avatarUrl: z.string().max(512).optional(),
  coverUrl: z.string().max(512).optional(),
});

const setAdminSchema = z.object({ userId: z.string().uuid(), grant: z.boolean() });

const superadminOnly = [requireAuth, requireFreshAuth, requireRole("superadmin")];

export async function storeRoutes(app: FastifyInstance): Promise<void> {
  // Public read (any authenticated user) — matches the old firestore.rules.
  app.get("/stores", { preHandler: requireAuth }, async (_req, reply) => {
    const stores = await prisma.store.findMany({
      where: { active: true },
      orderBy: { createdAt: "desc" },
    });
    return reply.send({ stores });
  });

  app.get("/stores/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const store = await prisma.store.findUnique({ where: { id } });
    if (!store) return reply.code(404).send({ error: "NOT_FOUND" });
    return reply.send({ store });
  });

  app.post("/stores", { preHandler: superadminOnly }, async (req, reply) => {
    const body = createStoreSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
    const store = await prisma.store.create({
      data: { ...body.data, createdById: req.auth!.sub },
    });
    return reply.code(201).send({ store });
  });

  // Store admin (of this store) or superadmin may edit the store's own fields.
  // Publishes to the store's realtime channel so open profiles update live.
  app.patch(
    "/stores/:id",
    {
      preHandler: [
        requireAuth,
        requireFreshAuth,
        requireStoreAdmin((req) => (req.params as { id: string }).id),
      ],
    },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const body = updateStoreSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
      const store = await prisma.store.update({ where: { id }, data: body.data });
      publish(`store:${id}`, { type: "upsert", data: store });
      return reply.send({ store });
    }
  );

  app.post(
    "/stores/:id/admins",
    { preHandler: superadminOnly },
    async (req, reply) => {
      const { id } = req.params as { id: string };
      const body = setAdminSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
      await setStoreAdmin(id, body.data.userId, body.data.grant);
      return reply.send({ ok: true });
    }
  );

  app.delete("/stores/:id", { preHandler: superadminOnly }, async (req, reply) => {
    const { id } = req.params as { id: string };
    await deleteStoreCascade(id);
    return reply.send({ ok: true });
  });

  // Public read, same as posts/stories — denormalized per-store per-user
  // order-quantity aggregate, top 20 by quantity.
  app.get("/stores/:id/leaderboard", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const entries = await prisma.storeLeaderboard.findMany({
      where: { storeId: id },
      orderBy: { quantity: "desc" },
      take: 20,
    });
    return reply.send({ entries });
  });
}
