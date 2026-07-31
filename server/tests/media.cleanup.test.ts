import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { keyForPublicUrl, MEDIA_DIR, publicUrlForKey } from "../src/media/storage.js";
import { createPost, deletePostCascade } from "../src/posts/service.js";
import { deleteStoreCascade } from "../src/stores/service.js";
import { createStore, createUserWithToken } from "./helpers.js";

// Nothing in the codebase deleted media files, so every removed post, story,
// store and account leaked its bytes forever — invisible in the DB and unbounded
// on disk. These tests hold the line on that.
async function fixture(name: string): Promise<{ key: string; url: string; abs: string }> {
  const key = `posts/${name}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`;
  const abs = path.join(MEDIA_DIR, key);
  await writeFile(abs, "bytes");
  return { key, url: publicUrlForKey(key), abs };
}

describe("media file cleanup", () => {
  const userIds: string[] = [];
  const storeIds: string[] = [];

  beforeAll(async () => {
    await mkdir(path.join(MEDIA_DIR, "posts"), { recursive: true });
  });

  afterAll(async () => {
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  it("removes a post's media and thumbnail from disk when the post is deleted", async () => {
    const admin = await createUserWithToken("admin");
    userIds.push(admin.userId);
    const store = await createStore("Cleanup Co", admin.userId);
    storeIds.push(store.id);

    const image = await fixture("post-image");
    const thumb = await fixture("post-thumb");

    const post = await createPost({
      storeId: store.id,
      type: "image",
      caption: "",
      media: [{ url: image.url, position: 0 }],
      thumbnailUrl: thumb.url,
    });

    expect(existsSync(image.abs)).toBe(true);
    await deletePostCascade(post.id);

    expect(existsSync(image.abs)).toBe(false);
    expect(existsSync(thumb.abs)).toBe(false);
  });

  it("removes every post's media when a whole store is deleted", async () => {
    const admin = await createUserWithToken("admin");
    userIds.push(admin.userId);
    const store = await createStore("Doomed Store", admin.userId);

    const a = await fixture("store-a");
    const b = await fixture("store-b");
    await createPost({
      storeId: store.id,
      type: "carousel",
      caption: "",
      media: [
        { url: a.url, position: 0 },
        { url: b.url, position: 1 },
      ],
    });

    await deleteStoreCascade(store.id);

    // A deleted store could otherwise strand gigabytes with nothing left in the
    // database pointing at it.
    expect(existsSync(a.abs)).toBe(false);
    expect(existsSync(b.abs)).toBe(false);
  });

  it("ignores URLs it does not own, so a crafted value can't delete arbitrary files", async () => {
    // Foreign origin, traversal, and a non-media path all resolve to "not ours".
    expect(keyForPublicUrl("https://evil.example.com/posts/x.jpg")).toBeUndefined();
    expect(keyForPublicUrl(publicUrlForKey("../../package.json"))).toBeUndefined();
    expect(keyForPublicUrl(publicUrlForKey("posts/../../secret.env"))).toBeUndefined();
    // A well-formed key of ours still resolves normally.
    expect(keyForPublicUrl(publicUrlForKey("posts/ok.jpg"))).toBe("posts/ok.jpg");
  });
});
