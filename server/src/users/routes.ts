import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { prisma } from "../db.js";
import { annotateWithUserFlags } from "../posts/service.js";
import { AccountDeletionBlockedError, deleteAccount, registerFcmToken } from "./service.js";

const updateMeSchema = z.object({
  name: z.string().max(120).optional(),
  avatarUrl: z.string().max(512).optional(),
  language: z.enum(["tk", "ru"]).optional(),
  darkMode: z.boolean().optional(),
  activeChatId: z.string().max(80).nullable().optional(),
});

const registerTokenSchema = z.object({
  token: z.string().min(10).max(255),
  platform: z.enum(["android", "ios"]).optional(),
});

const listQuerySchema = z.object({
  limit: z.coerce.number().int().positive().max(100).default(20),
  offset: z.coerce.number().int().nonnegative().default(0),
});

function toProfile(user: {
  id: string;
  phone: string;
  name: string;
  avatarUrl: string;
  role: string;
  language: string;
  darkMode: boolean;
  activeChatId: string | null;
}) {
  return {
    id: user.id,
    phone: user.phone,
    name: user.name,
    avatarUrl: user.avatarUrl,
    role: user.role,
    language: user.language,
    darkMode: user.darkMode,
    activeChatId: user.activeChatId,
  };
}

export async function userRoutes(app: FastifyInstance): Promise<void> {
  app.get("/users/me", { preHandler: requireAuth }, async (req, reply) => {
    const user = await prisma.user.findUniqueOrThrow({ where: { id: req.auth!.sub } });
    return reply.send({ user: toProfile(user) });
  });

  // Minimal public profile of another user — used by the admin's chat thread
  // header to show the customer's name/avatar. `phone` is included only when
  // the requester is an admin/superadmin (a store admin talking to that
  // customer legitimately sees their number, same as the old chat did) — a
  // plain user never sees another user's phone.
  app.get("/users/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const user = await prisma.user.findUnique({
      where: { id },
      select: { id: true, name: true, avatarUrl: true, phone: true },
    });
    if (!user) return reply.code(404).send({ error: "NOT_FOUND" });
    const canSeePhone = req.auth!.role === "admin" || req.auth!.role === "superadmin";
    return reply.send({
      user: {
        id: user.id,
        name: user.name,
        avatarUrl: user.avatarUrl,
        ...(canSeePhone ? { phone: user.phone } : {}),
      },
    });
  });

  app.patch("/users/me", { preHandler: requireAuth }, async (req, reply) => {
    const body = updateMeSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }
    const user = await prisma.user.update({
      where: { id: req.auth!.sub },
      data: body.data,
    });
    return reply.send({ user: toProfile(user) });
  });

  // Self-service account deletion (App Store / Play Store both require it).
  // requireFreshAuth so a token minted before the caller was granted store-admin
  // can't be replayed to slip past the store-owner check inside deleteAccount.
  app.delete("/users/me", { preHandler: [requireAuth, requireFreshAuth] }, async (req, reply) => {
    try {
      await deleteAccount(req.auth!.sub);
    } catch (err) {
      if (err instanceof AccountDeletionBlockedError) {
        return reply.code(409).send({ error: "STORE_OWNER_CANNOT_DELETE" });
      }
      // No branch for AccountAlreadyDeletedError: a tombstone can never produce
      // valid claims again (auth/claims.ts), so requireFreshAuth rejects a
      // replayed delete with 401 ACCOUNT_DELETED before reaching this call. The
      // service keeps that guard for direct/programmatic callers.
      throw err;
    }
    return reply.send({ ok: true });
  });

  // UNIQUE(token) + upsert-on-conflict — reinstall/relogin on the same device
  // reassigns the token's ownership instead of the old arrayUnion ambiguity
  // (two accounts both believing they own a stale token on the same phone).
  app.post("/users/me/fcm-tokens", { preHandler: requireAuth }, async (req, reply) => {
    const body = registerTokenSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });
    await registerFcmToken(req.auth!.sub, body.data.token, body.data.platform);
    return reply.send({ ok: true });
  });

  app.delete("/users/me/fcm-tokens/:token", { preHandler: requireAuth }, async (req, reply) => {
    const { token } = req.params as { token: string };
    await prisma.userFcmToken.deleteMany({ where: { token, userId: req.auth!.sub } });
    return reply.send({ ok: true });
  });

  // "My Liked" / "My Saved" grids (profile/liked_screen.dart). Served directly
  // off post_likes/post_saves' INDEX(userId, createdAt) — the old
  // users/{uid}/liked and /saved Firestore mirror collections are gone (see
  // docs/07_MIGRATION.md); this index replaces them.
  app.get("/users/me/liked", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const rows = await prisma.postLike.findMany({
      where: { userId: req.auth!.sub },
      orderBy: { createdAt: "desc" },
      take: query.data.limit,
      skip: query.data.offset,
      include: { post: { include: { media: { orderBy: { position: "asc" } } } } },
    });
    const posts = await annotateWithUserFlags(
      rows.map((r) => r.post),
      req.auth!.sub
    );
    return reply.send({ posts });
  });

  app.get("/users/me/saved", { preHandler: requireAuth }, async (req, reply) => {
    const query = listQuerySchema.safeParse(req.query);
    if (!query.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const rows = await prisma.postSave.findMany({
      where: { userId: req.auth!.sub },
      orderBy: { createdAt: "desc" },
      take: query.data.limit,
      skip: query.data.offset,
      include: { post: { include: { media: { orderBy: { position: "asc" } } } } },
    });
    const posts = await annotateWithUserFlags(
      rows.map((r) => r.post),
      req.auth!.sub
    );
    return reply.send({ posts });
  });
}
