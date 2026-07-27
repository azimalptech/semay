import { Prisma, type Post, type PostType } from "@prisma/client";

import { prisma } from "../db.js";
import { publish } from "../realtime/bus.js";

const POST_COUNTS_SELECT = {
  id: true,
  likesCount: true,
  savesCount: true,
  viewsCount: true,
  sentCount: true,
  sharesCount: true,
} as const;

async function publishPostCounts(postId: string): Promise<void> {
  const post = await prisma.post.findUnique({ where: { id: postId }, select: POST_COUNTS_SELECT });
  if (post) publish(`post:${postId}`, { type: "upsert", data: post });
}

export interface CreatePostInput {
  storeId: string;
  type: PostType;
  caption: string;
  price?: number;
  thumbnailUrl?: string;
  media: { url: string; position: number; thumbnailUrl?: string }[];
}

// Store's postsCount/reelsCount are denormalized counters — this replaces the
// old onPostCreated/onPostDeleted Firestore triggers with a same-transaction
// update instead of an async trigger.
export async function createPost(input: CreatePostInput): Promise<Post> {
  return prisma.$transaction(async (tx) => {
    const post = await tx.post.create({
      data: {
        storeId: input.storeId,
        type: input.type,
        caption: input.caption,
        price: input.price,
        thumbnailUrl: input.thumbnailUrl ?? "",
        media: { createMany: { data: input.media } },
      },
      include: { media: { orderBy: { position: "asc" } } },
    });
    await tx.store.update({
      where: { id: input.storeId },
      data:
        input.type === "reel"
          ? { reelsCount: { increment: 1 } }
          : { postsCount: { increment: 1 } },
    });
    return post;
  });
}

export async function updateCaption(postId: string, caption: string): Promise<Post> {
  const post = await prisma.post.update({ where: { id: postId }, data: { caption } });
  publish(`post:${postId}`, { type: "upsert", data: post });
  return post;
}

export async function deletePostCascade(postId: string): Promise<void> {
  const post = await prisma.post.findUniqueOrThrow({
    where: { id: postId },
    select: { storeId: true, type: true },
  });
  await prisma.$transaction(async (tx) => {
    await tx.post.delete({ where: { id: postId } }); // cascades media/likes/saves/views/sent/shares
    await tx.store.update({
      where: { id: post.storeId },
      data:
        post.type === "reel"
          ? { reelsCount: { decrement: 1 } }
          : { postsCount: { decrement: 1 } },
    });
  });
}

function isDuplicateKeyError(err: unknown): boolean {
  return err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002";
}

export interface InteractionBatchItem {
  postId: string;
  views?: number;
  sent?: number;
  shares?: number;
}

/** Applies a batch of buffered view/send/share increments from the mobile
 * client's local interaction buffer. Unlike the old once-ever recordOnce, these
 * are pure counter increments: the client now enforces the per-user 30-minute
 * re-count window locally and flushes already-deduped totals every 30 minutes
 * (see mobile/lib/core/interaction_buffer.dart), so the server just adds them
 * and republishes the aggregate counts. That's why view/sent/share dropped
 * their per-user PostView/PostSent/PostShare rows — the dedup moved client-side,
 * where the 30-minute window and offline batching live. Zero/omitted fields are
 * skipped; an unknown/deleted postId is ignored rather than failing the batch. */
export async function applyInteractionBatch(items: InteractionBatchItem[]): Promise<void> {
  const touched = new Set<string>();
  for (const item of items) {
    const data: Record<string, { increment: number }> = {};
    if (item.views && item.views > 0) data.viewsCount = { increment: item.views };
    if (item.sent && item.sent > 0) data.sentCount = { increment: item.sent };
    if (item.shares && item.shares > 0) data.sharesCount = { increment: item.shares };
    if (Object.keys(data).length === 0) continue;
    try {
      await prisma.post.update({ where: { id: item.postId }, data });
      touched.add(item.postId);
    } catch (err) {
      // P2025 = record-to-update not found (post deleted since the tap). Skip it
      // so one stale id can't reject a whole flush; anything else is real.
      if (!(err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2025")) throw err;
    }
  }
  // Published after the writes commit (never mid-transaction) so a subscriber
  // never observes a count that could still roll back.
  await Promise.all([...touched].map((id) => publishPostCounts(id)));
}

/** Toggle for like/save — add is idempotent (duplicate insert ignored), remove
 * only decrements if a row actually existed. */
async function setToggle(
  postId: string,
  userId: string,
  on: boolean,
  model: "postLike" | "postSave",
  countField: "likesCount" | "savesCount"
): Promise<void> {
  const changed = await prisma.$transaction(async (tx) => {
    if (on) {
      try {
        // @ts-expect-error -- model is one of two delegates sharing this shape
        await tx[model].create({ data: { postId, userId } });
      } catch (err) {
        if (isDuplicateKeyError(err)) return false;
        throw err;
      }
      await tx.post.update({ where: { id: postId }, data: { [countField]: { increment: 1 } } });
      return true;
    }
    // @ts-expect-error -- model is one of two delegates sharing this shape
    const deleted = await tx[model].deleteMany({ where: { postId, userId } });
    if (deleted.count === 0) return false;
    await tx.post.update({ where: { id: postId }, data: { [countField]: { decrement: 1 } } });
    return true;
  });
  if (changed) await publishPostCounts(postId);
}

export const setLike = (postId: string, userId: string, on: boolean) =>
  setToggle(postId, userId, on, "postLike", "likesCount");
export const setSave = (postId: string, userId: string, on: boolean) =>
  setToggle(postId, userId, on, "postSave", "savesCount");

/** Adds `likedByMe`/`savedByMe` to each post for the requesting user. The
 * realtime `post:{id}` channel only carries aggregate counts by design (a
 * private "did I like this" flag has no cross-device live-update value), so
 * these per-request booleans are what replace the old Firestore per-post
 * existence checks (isLikedProvider/isSavedProvider). Two batched `IN`
 * queries regardless of page size, not one lookup per post. */
export async function annotateWithUserFlags<T extends { id: string }>(
  posts: T[],
  userId: string
): Promise<(T & { likedByMe: boolean; savedByMe: boolean })[]> {
  if (posts.length === 0) return [];
  const ids = posts.map((p) => p.id);
  const [likes, saves] = await Promise.all([
    prisma.postLike.findMany({ where: { userId, postId: { in: ids } }, select: { postId: true } }),
    prisma.postSave.findMany({ where: { userId, postId: { in: ids } }, select: { postId: true } }),
  ]);
  const likedSet = new Set(likes.map((l) => l.postId));
  const savedSet = new Set(saves.map((s) => s.postId));
  return posts.map((p) => ({
    ...p,
    likedByMe: likedSet.has(p.id),
    savedByMe: savedSet.has(p.id),
  }));
}
