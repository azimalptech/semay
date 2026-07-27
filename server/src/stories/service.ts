import { Prisma, type Story, type StoryMediaType } from "@prisma/client";

import { prisma } from "../db.js";

const STORY_LIFETIME_MS = 24 * 60 * 60 * 1000;

export async function createStory(
  storeId: string,
  mediaUrl: string,
  mediaType: StoryMediaType
): Promise<Story> {
  const now = new Date();
  return prisma.story.create({
    data: {
      storeId,
      mediaUrl,
      mediaType,
      expiresAt: new Date(now.getTime() + STORY_LIFETIME_MS),
    },
  });
}

export interface StoryRing {
  storeId: string;
  storeName: string;
  avatarUrl: string;
  hasStories: boolean;
  seen: boolean;
  isOwn: boolean;
}

/** Everything the home story bar needs, computed server-side (the old
 * Firestore version stitched this together client-side from three separate
 * listeners: active stories, storySeen, and per-store docs). Returns one ring
 * per store that either has an active story OR is administered by the caller
 * (own stores always show as the "+" add-story entry point), sorted own-first,
 * then unseen, then newest. */
export async function getStoryRings(userId: string, ownStoreIds: string[]): Promise<StoryRing[]> {
  const [activeStories, seenRows] = await Promise.all([
    prisma.story.findMany({
      where: { expiresAt: { gt: new Date() } },
      select: { storeId: true, createdAt: true },
    }),
    prisma.userStorySeen.findMany({ where: { userId }, select: { storeId: true, seenAt: true } }),
  ]);

  // storeId -> latest active story time
  const latestByStore = new Map<string, Date>();
  for (const s of activeStories) {
    const cur = latestByStore.get(s.storeId);
    if (!cur || s.createdAt > cur) latestByStore.set(s.storeId, s.createdAt);
  }
  const seenByStore = new Map(seenRows.map((r) => [r.storeId, r.seenAt]));

  const storeIds = new Set<string>([...latestByStore.keys(), ...ownStoreIds]);
  if (storeIds.size === 0) return [];

  const stores = await prisma.store.findMany({
    where: { id: { in: [...storeIds] } },
    select: { id: true, name: true, avatarUrl: true },
  });

  const rings: StoryRing[] = stores.map((store) => {
    const latestAt = latestByStore.get(store.id) ?? null;
    const seenAt = seenByStore.get(store.id) ?? null;
    return {
      storeId: store.id,
      storeName: store.name,
      avatarUrl: store.avatarUrl,
      hasStories: latestAt !== null,
      seen: latestAt !== null && seenAt !== null && seenAt >= latestAt,
      isOwn: ownStoreIds.includes(store.id),
    };
  });

  const latestMillis = (r: StoryRing) => latestByStore.get(r.storeId)?.getTime() ?? 0;
  rings.sort((a, b) => {
    if (a.isOwn !== b.isOwn) return a.isOwn ? -1 : 1;
    if (a.seen !== b.seen) return a.seen ? 1 : -1;
    return latestMillis(b) - latestMillis(a);
  });
  return rings;
}

/** Stamps user_story_seen for a whole store (the "watched to the end" signal
 * the story viewer records on the last story) — separate from recordStoryView
 * because the owner marks their own store seen without counting a view. */
export async function markStoreSeen(storeId: string, userId: string): Promise<void> {
  await prisma.userStorySeen.upsert({
    where: { userId_storeId: { userId, storeId } },
    create: { userId, storeId },
    update: { seenAt: new Date() },
  });
}

/** Records the view (create-only, harmless repeat) and stamps
 * user_story_seen for the story's store — replaces users/{uid}/storySeen. */
export async function recordStoryView(storyId: string, userId: string): Promise<void> {
  const story = await prisma.story.findUniqueOrThrow({
    where: { id: storyId },
    select: { storeId: true },
  });

  await prisma.$transaction(async (tx) => {
    try {
      await tx.storyView.create({ data: { storyId, userId } });
    } catch (err) {
      if (!(err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002")) {
        throw err;
      }
    }
    await tx.userStorySeen.upsert({
      where: { userId_storeId: { userId, storeId: story.storeId } },
      create: { userId, storeId: story.storeId },
      update: { seenAt: new Date() },
    });
  });
}
