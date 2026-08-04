import { afterAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { setLike, setSave } from "../src/posts/service.js";
import { createStore, createUserWithToken } from "./helpers.js";

// store.likesCount backs the "Halananlar" stat on the store detail header
// (Figma 223:5365). It is maintained inside the same transaction as the per-post
// likesCount so the two can't disagree, and clamped at zero because it starts
// un-backfilled — unliking a like that predates the counter must not drive the
// store total negative.
describe("store likes rollup", () => {
  const userIds: string[] = [];
  const storeIds: string[] = [];

  afterAll(async () => {
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  async function fixture(name: string) {
    const owner = await createUserWithToken("admin");
    userIds.push(owner.userId);
    const store = await createStore(name, owner.userId);
    storeIds.push(store.id);
    const post = await prisma.post.create({
      data: { storeId: store.id, type: "image", caption: "", thumbnailUrl: "" },
    });
    return { owner, store, post };
  }

  it("increments and decrements with likes, tracking the post counter", async () => {
    const { owner, store, post } = await fixture("Rollup Co");
    const other = await createUserWithToken("user");
    userIds.push(other.userId);

    await setLike(post.id, owner.userId, true);
    await setLike(post.id, other.userId, true);

    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(2);
    expect((await prisma.post.findUniqueOrThrow({ where: { id: post.id } })).likesCount).toBe(2);

    await setLike(post.id, other.userId, false);
    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(1);
    expect((await prisma.post.findUniqueOrThrow({ where: { id: post.id } })).likesCount).toBe(1);
  });

  it("does not double-count a repeated like, or under-count a repeated unlike", async () => {
    const { owner, store, post } = await fixture("Rollup Co 2");

    await setLike(post.id, owner.userId, true);
    await setLike(post.id, owner.userId, true); // idempotent
    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(1);

    await setLike(post.id, owner.userId, false);
    await setLike(post.id, owner.userId, false); // no row to delete
    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(0);
  });

  it("never goes negative when unliking a like that predates the counter", async () => {
    const { owner, store, post } = await fixture("Rollup Co 3");

    // Simulate history: a like row exists and the POST counter reflects it, but
    // the store total is still 0 because it was never backfilled.
    await prisma.postLike.create({ data: { postId: post.id, userId: owner.userId } });
    await prisma.post.update({ where: { id: post.id }, data: { likesCount: 1 } });
    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(0);

    await setLike(post.id, owner.userId, false);

    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(0);
  });

  it("saves do not touch the store likes total", async () => {
    const { owner, store, post } = await fixture("Rollup Co 4");

    await setSave(post.id, owner.userId, true);

    expect((await prisma.store.findUniqueOrThrow({ where: { id: store.id } })).likesCount).toBe(0);
    expect((await prisma.post.findUniqueOrThrow({ where: { id: post.id } })).savesCount).toBe(1);
  });
});
