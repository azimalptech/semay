import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { createPost, setLike } from "../src/posts/service.js";
import { createStore, createUserWithToken } from "./helpers.js";

// Regression test for a deadlock found by load testing, not by review.
//
// Liking a post inserts a post_likes row and then increments posts.likesCount.
// Because post_likes.postId is a foreign key, the INSERT takes a SHARED lock on
// the parent posts row, and the UPDATE straight after needs that same row
// EXCLUSIVELY. Two concurrent likes on one post therefore each held S and each
// waited to upgrade to X, and InnoDB resolved it the only way it can — by
// rolling one of them back. Under 50 concurrent likes on a single post this
// failed 7.5% of requests with HTTP 500, and setToggle had no retry wrapper at
// all, so every deadlock reached the user.
//
// The fix takes the exclusive lock up front (posts, then stores — always that
// order) so contention becomes a queue instead of a deadlock. This test pins
// both halves of that: no request may fail, and the counters must land exactly,
// since a silently-swallowed rollback would show up as a short count.
/** InnoDB's running total of deadlock cycles it has had to break. Global to the
 * server, so this only reads cleanly because the suite runs serially against a
 * local database — if this test ever turns flaky, an unrelated process writing
 * to the same MySQL is the first thing to check. */
async function deadlockCount(): Promise<number> {
  const rows =
    await prisma.$queryRaw<{ Variable_name: string; Value: string }[]>`SHOW GLOBAL STATUS LIKE 'Innodb_deadlocks'`;
  return Number(rows[0]?.Value ?? 0);
}

describe("concurrent likes on one post", () => {
  let userIds: string[] = [];
  let storeId: string;
  let postId: string;

  const LIKERS = 40;

  beforeAll(async () => {
    const owner = await createUserWithToken("admin");
    const store = await createStore("Like Concurrency Store", owner.userId);
    storeId = store.id;

    const post = await createPost({
      storeId,
      type: "image",
      caption: "contention target",
      thumbnailUrl: "",
      media: [],
    });
    postId = post.id;

    const likers = await Promise.all(
      Array.from({ length: LIKERS }, () => createUserWithToken("user"))
    );
    userIds = [owner.userId, ...likers.map((l) => l.userId)];
  });

  afterAll(async () => {
    await prisma.store.delete({ where: { id: storeId } }); // cascades posts + likes
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  it("never fails, and every like is counted exactly once", async () => {
    const likers = userIds.slice(1);
    const before = await deadlockCount();

    const results = await Promise.allSettled(likers.map((id) => setLike(postId, id, true)));
    expect(results.filter((r) => r.status === "rejected")).toEqual([]);

    // The counter assertions below pass even with the lock ordering removed,
    // because withRetry quietly re-runs the rolled-back transaction. So assert
    // on the thing the ordering actually changes: InnoDB should not have had to
    // break a deadlock cycle at all. Without the up-front FOR UPDATE this rises
    // by roughly the number of concurrent likers.
    expect(await deadlockCount()).toBe(before);

    const post = await prisma.post.findUniqueOrThrow({
      where: { id: postId },
      select: { likesCount: true },
    });
    expect(post.likesCount).toBe(LIKERS);

    // The store roll-up is maintained in the same transaction, so it must agree.
    const store = await prisma.store.findUniqueOrThrow({
      where: { id: storeId },
      select: { likesCount: true },
    });
    expect(store.likesCount).toBe(LIKERS);
  });

  it("unlikes the same way, without dropping or double-counting", async () => {
    const likers = userIds.slice(1);

    const results = await Promise.allSettled(likers.map((id) => setLike(postId, id, false)));
    expect(results.filter((r) => r.status === "rejected")).toEqual([]);

    const post = await prisma.post.findUniqueOrThrow({
      where: { id: postId },
      select: { likesCount: true },
    });
    expect(post.likesCount).toBe(0);

    const store = await prisma.store.findUniqueOrThrow({
      where: { id: storeId },
      select: { likesCount: true },
    });
    expect(store.likesCount).toBe(0);
  });

  it("is idempotent — the same user liking repeatedly counts once", async () => {
    const liker = userIds[1]!;

    await Promise.allSettled(Array.from({ length: 8 }, () => setLike(postId, liker, true)));

    const post = await prisma.post.findUniqueOrThrow({
      where: { id: postId },
      select: { likesCount: true },
    });
    expect(post.likesCount).toBe(1);
  });
});
