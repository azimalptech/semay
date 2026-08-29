import { Prisma, type Post, type PostType } from "@prisma/client";

import { prisma } from "../db.js";
import { deleteMediaByUrls } from "../media/storage.js";
import { withRetry } from "../lib/withRetry.js";
import { publish } from "../realtime/bus.js";

const POST_COUNTS_SELECT = {
  id: true,
  likesCount: true,
  savesCount: true,
  viewsCount: true,
  sentCount: true,
  sharesCount: true,
} as const;

/** Publishes a post's counters on its channel.
 *
 * The channel is built from the id the DATABASE returned, never the caller's
 * string. MySQL matches `posts.id` case-insensitively, so a request naming
 * `ABC…` updates the row `abc…` — and publishing on `post:ABC…` delivered the
 * event to nobody, because every subscriber is on the canonical spelling. The
 * write succeeded and open clients silently kept a stale count. Selecting `id`
 * back and using it fixes this for every caller at once. */
async function publishPostCounts(postId: string): Promise<void> {
  const post = await prisma.post.findUnique({
    where: { id: postId },
    select: POST_COUNTS_SELECT,
  });
  if (post) publish(`post:${post.id}`, { type: "upsert", data: post });
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
  return withRetry(() => prisma.$transaction(async (tx) => {
    // Same up-front exclusive lock as setToggle, for the same reason: the post
    // INSERT takes a shared lock on the parent stores row via posts.storeId,
    // and the counter UPDATE below needs it exclusively. Two admins of one
    // store posting simultaneously is rare but not impossible, and the cost of
    // ordering the lock correctly is one extra indexed row read.
    await tx.$queryRaw`SELECT id FROM stores WHERE id = ${input.storeId} FOR UPDATE`;

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
  }));
}

export async function updateCaption(postId: string, caption: string): Promise<Post> {
  const post = await prisma.post.update({ where: { id: postId }, data: { caption } });
  publish(`post:${postId}`, { type: "upsert", data: post });
  return post;
}

export async function deletePostCascade(postId: string): Promise<void> {
  const post = await prisma.post.findUniqueOrThrow({
    where: { id: postId },
    // media/thumbnail URLs are read BEFORE the delete — the rows cascade away, so
    // afterwards there is nothing left to tell us which files to clean up.
    select: {
      storeId: true,
      type: true,
      thumbnailUrl: true,
      // Needed to keep store.likesCount honest — the post's likes cascade away
      // with it, so the store total has to shed exactly this many.
      likesCount: true,
      media: { select: { url: true } },
    },
  });
  await withRetry(() => prisma.$transaction(async (tx) => {
    // Lock the store row before the delete, matching createPost/setToggle —
    // the cascade touches posts.storeId's foreign key, so the same shared-then-
    // exclusive upgrade applies here.
    await tx.$queryRaw`SELECT id FROM stores WHERE id = ${post.storeId} FOR UPDATE`;
    await tx.post.delete({ where: { id: postId } }); // cascades media/likes/saves/views/sent/shares
    await tx.store.update({
      where: { id: post.storeId },
      data:
        post.type === "reel"
          ? { reelsCount: { decrement: 1 } }
          : { postsCount: { decrement: 1 } },
    });

    // Deleting a post silently dropped its post_likes rows while leaving
    // store.likesCount untouched, so the store's "Halananlar" total drifted
    // upward permanently — schema.prisma claims this counter "can't drift", and
    // there is no reaper to repair it. Clamped at zero for the same reason
    // setToggle clamps: the counter started at 0 with no backfill, so likes
    // predating it would otherwise push the total negative.
    if (post.likesCount > 0) {
      await tx.store.updateMany({
        where: { id: post.storeId, likesCount: { gte: post.likesCount } },
        data: { likesCount: { decrement: post.likesCount } },
      });
      await tx.store.updateMany({
        where: { id: post.storeId, likesCount: { lt: post.likesCount } },
        data: { likesCount: 0 },
      });
    }
  }));

  // After the commit: the DB is the source of truth, so files are only removed
  // once the rows referencing them are definitely gone. Best-effort by design
  // (see deleteMediaByUrl) — a stray file is recoverable, a failed delete of an
  // already-deleted post is not.
  await deleteMediaByUrls([...post.media.map((m) => m.url), post.thumbnailUrl]);
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

  // Collapse repeats of the same postId before applying. The per-item cap in
  // routes.ts bounds ONE entry, but nothing stopped a caller listing the same
  // post 1000 times in a single batch to multiply it back up. A real client
  // aggregates per post before sending (interaction_buffer.dart builds a map
  // keyed by postId), so duplicates only ever arrive from a crafted request.
  //
  // The key is CANONICALISED, and that is the whole point. A plain Map keyed on
  // the raw string compares exactly, while MySQL matches the id column
  // case-insensitively and ignores trailing spaces — so "abc…", "ABC…" and
  // "abc… " were three separate map entries that all updated the SAME row,
  // three times. The cap was bypassable by simply varying the case: 1000
  // spellings of one uuid in a single request incremented every counter by
  // 1000, against any post of any store, which is precisely the amplification
  // the cap was introduced to close.
  //
  // Ids here are uuids, so lowercasing and trimming reproduces exactly what the
  // collation does.
  const canonicalKey = (postId: string): string => postId.trim().toLowerCase();

  const merged = new Map<string, InteractionBatchItem>();
  for (const item of items) {
    const key = canonicalKey(item.postId);
    const prev = merged.get(key);
    if (!prev) {
      merged.set(key, { ...item });
      continue;
    }
    prev.views = Math.max(prev.views ?? 0, item.views ?? 0);
    prev.sent = Math.max(prev.sent ?? 0, item.sent ?? 0);
    prev.shares = Math.max(prev.shares ?? 0, item.shares ?? 0);
  }

  for (const item of merged.values()) {
    const data: Record<string, { increment: number }> = {};
    if (item.views && item.views > 0) data.viewsCount = { increment: item.views };
    if (item.sent && item.sent > 0) data.sentCount = { increment: item.sent };
    if (item.shares && item.shares > 0) data.sharesCount = { increment: item.shares };
    if (Object.keys(data).length === 0) continue;
    try {
      // Track the id the DATABASE returns, not the one the caller sent. The
      // realtime channel is derived from it, and a caller-supplied variant
      // spelling published to `post:ABC…` while every real subscriber listens
      // on `post:abc…` — the write landed and no one was told, leaving open
      // clients showing a stale count indefinitely.
      const updated = await prisma.post.update({
        where: { id: item.postId },
        data,
        select: { id: true },
      });
      touched.add(updated.id);
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
  // Likes additionally roll up to the store's own total (the "Halananlar" stat
  // on the store detail header). Kept inside the same transaction as the
  // per-post counter so the two can never disagree — a store total maintained
  // outside the transaction would drift on any rollback. Saves don't roll up:
  // there is no store-level saves stat in the design.
  const rollsUpToStore = countField === "likesCount";

  const changed = await withRetry(() => prisma.$transaction(async (tx) => {
    // Lock the rows this transaction is going to UPDATE before writing the
    // like/save row, and always in the same order: post, then store.
    //
    // This is the highest-concurrency write in the product, and without the
    // up-front lock it deadlocked on 7.5% of requests under 50 concurrent
    // likes on one post (measured, not estimated — see docs/08_OPERATIONS.md
    // §7). `postLike.postId` is a foreign key, so inserting the like takes a
    // SHARED lock on the parent posts row; the counter UPDATE immediately
    // after needs that same row EXCLUSIVELY. Two likes on one post therefore
    // both hold S and both wait to upgrade to X, and InnoDB breaks the tie by
    // killing one of them. Taking X first turns that into a plain queue.
    //
    // Ordering post-before-store matters as much as the locking itself: a
    // transaction that took them in the opposite order would reintroduce
    // deadlocks between different callers rather than within one.
    const locked = await tx.$queryRaw<{ storeId: string }[]>`
      SELECT storeId FROM posts WHERE id = ${postId} FOR UPDATE
    `;
    // Post deleted between the request and this lock — nothing to toggle.
    if (locked.length === 0) return false;
    const storeId = locked[0]!.storeId;
    if (rollsUpToStore) {
      await tx.$queryRaw`SELECT id FROM stores WHERE id = ${storeId} FOR UPDATE`;
    }

    if (on) {
      try {
        // @ts-expect-error -- model is one of two delegates sharing this shape
        await tx[model].create({ data: { postId, userId } });
      } catch (err) {
        if (isDuplicateKeyError(err)) return false;
        throw err;
      }
      await tx.post.update({
        where: { id: postId },
        data: { [countField]: { increment: 1 } },
      });
      if (rollsUpToStore) {
        await tx.store.update({
          where: { id: storeId },
          data: { likesCount: { increment: 1 } },
        });
      }
      return true;
    }
    // @ts-expect-error -- model is one of two delegates sharing this shape
    const deleted = await tx[model].deleteMany({ where: { postId, userId } });
    if (deleted.count === 0) return false;
    await tx.post.update({
      where: { id: postId },
      data: { [countField]: { decrement: 1 } },
    });
    if (rollsUpToStore) {
      // Clamped at zero: the counter starts from 0 by design (no backfill), so
      // unliking a post that was liked BEFORE the counter existed would
      // otherwise drive the store total negative.
      await tx.store.updateMany({
        where: { id: storeId, likesCount: { gt: 0 } },
        data: { likesCount: { decrement: 1 } },
      });
    }
    return true;
  }));
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
