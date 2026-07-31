import { bumpClaimsVersion } from "../auth/claims.js";
import { prisma } from "../db.js";
import { deleteMediaByUrls } from "../media/storage.js";

/** Grants/revokes store-admin for a user. Revoking down to zero managed stores
 * demotes them back to role='user' — same transition deleteStoreCascade uses.
 * claims_version is always bumped so their next request/refresh sees the change
 * instead of riding out a stale access token.
 *
 * Role is only ever adjusted between 'user' and 'admin' — a 'superadmin' is
 * NEVER touched by this function in either direction. This used to unconditionally
 * overwrite role on grant, which meant promoting a superadmin's own account as a
 * store's admin (e.g. while testing this exact feature) silently demoted them to
 * a plain store admin, locking them out of the superadmin panel with no error —
 * a real incident this guard exists to prevent from recurring. */
export async function setStoreAdmin(
  storeId: string,
  userId: string,
  grant: boolean
): Promise<void> {
  await prisma.$transaction(async (tx) => {
    const user = await tx.user.findUniqueOrThrow({ where: { id: userId }, select: { role: true } });

    if (grant) {
      await tx.storeAdmin.upsert({
        where: { storeId_userId: { storeId, userId } },
        create: { storeId, userId },
        update: {},
      });
      if (user.role === "user") {
        await tx.user.update({ where: { id: userId }, data: { role: "admin" } });
      }
    } else {
      await tx.storeAdmin.deleteMany({ where: { storeId, userId } });
      const remaining = await tx.storeAdmin.count({ where: { userId } });
      if (remaining === 0 && user.role === "admin") {
        await tx.user.update({ where: { id: userId }, data: { role: "user" } });
      }
    }
    await bumpClaimsVersion(tx, userId);
  });
}

/** Every media URL owned by a store, gathered in pages so a store with a long
 * history can't load its entire media list into memory at once.
 *
 * Must run BEFORE the delete: the rows cascade away, and afterwards nothing is
 * left to say which files belonged to this store. */
async function collectStoreMediaUrls(storeId: string): Promise<string[]> {
  const PAGE = 1_000;
  const urls: string[] = [];

  const store = await prisma.store.findUnique({
    where: { id: storeId },
    select: { avatarUrl: true, coverUrl: true, campaignImageUrl: true },
  });
  if (store) {
    urls.push(store.avatarUrl, store.coverUrl, store.campaignImageUrl ?? "");
  }

  for (let skip = 0; ; skip += PAGE) {
    const posts = await prisma.post.findMany({
      where: { storeId },
      select: { thumbnailUrl: true, media: { select: { url: true } } },
      take: PAGE,
      skip,
    });
    if (posts.length === 0) break;
    for (const p of posts) {
      urls.push(p.thumbnailUrl);
      for (const m of p.media) urls.push(m.url);
    }
    if (posts.length < PAGE) break;
  }

  for (let skip = 0; ; skip += PAGE) {
    const stories = await prisma.story.findMany({
      where: { storeId },
      select: { mediaUrl: true },
      take: PAGE,
      skip,
    });
    if (stories.length === 0) break;
    for (const s of stories) urls.push(s.mediaUrl);
    if (stories.length < PAGE) break;
  }

  // Chat attachments sent in this store's threads.
  for (let skip = 0; ; skip += PAGE) {
    const messages = await prisma.message.findMany({
      where: { chat: { storeId }, mediaUrl: { not: null } },
      select: { mediaUrl: true },
      take: PAGE,
      skip,
    });
    if (messages.length === 0) break;
    for (const m of messages) urls.push(m.mediaUrl ?? "");
    if (messages.length < PAGE) break;
  }

  return urls.filter((u) => u.length > 0);
}

/** Irreversible cascade delete. FK ON DELETE CASCADE on posts/stories/chats/
 * orders/leaderboard/quickReplies/notificationRequests/storeAdmins (see
 * schema.prisma) does the relational cleanup; this function's own job is the
 * cross-entity side effects FKs can't express — demoting admins who end up with
 * zero managed stores after their storeAdmin rows cascade-delete, and removing
 * the store's media files, which no FK can reach.
 *
 * Same guard as setStoreAdmin: only a plain 'admin' is ever demoted to 'user'
 * here. A superadmin who happened to be listed as this store's admin keeps
 * their role — deleting a store must never be a way to lose superadmin access. */
export async function deleteStoreCascade(storeId: string): Promise<void> {
  const admins = await prisma.storeAdmin.findMany({
    where: { storeId },
    select: { userId: true, user: { select: { role: true } } },
  });
  const mediaUrls = await collectStoreMediaUrls(storeId);

  await prisma.$transaction(async (tx) => {
    await tx.store.delete({ where: { id: storeId } });
    for (const { userId, user } of admins) {
      const remaining = await tx.storeAdmin.count({ where: { userId } });
      if (remaining === 0 && user.role === "admin") {
        await tx.user.update({ where: { id: userId }, data: { role: "user" } });
      }
      await bumpClaimsVersion(tx, userId);
    }
  });

  // Only after the rows are definitely gone — a crash in between leaves
  // recoverable stray files rather than rows pointing at deleted media.
  await deleteMediaByUrls(mediaUrls);
}
