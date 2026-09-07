import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import {
  authHeader,
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  type App,
} from "./helpers.js";

// Reels vanished from the home feed in the Firebase->MySQL migration: the
// Firestore feed had no type filter, but GET /feed was written with a hard
// `type IN ('image','carousel')`, so every reel was silently dropped and the
// `type` query param the route already parsed was ignored. The feed is now
// every type in one createdAt stream (reels interleave as inline video
// cards), `?type=` is a real filter, and GET /reels keeps its reels-only
// contract for the Reels tab.
describe("reels-in-feed: GET /feed", () => {
  let app: App;
  let ownerId: string;
  let viewerId: string;
  let viewerToken: string;
  let storeId: string;
  let imageId: string;
  let reelId: string;
  let carouselId: string;

  // Fixture posts are dated a year out so they are the newest rows in the
  // shared dev database no matter what other suites insert at now().
  const base = Date.now() + 365 * 24 * 60 * 60 * 1000;

  beforeAll(async () => {
    app = await buildApp();
    const owner = await createUserWithToken("superadmin");
    ownerId = owner.userId;
    // A separate reader with no likes/saves, so the likedByMe/savedByMe
    // annotation is exercised for the row shape the phone actually receives.
    const viewer = await createUserWithToken("user");
    viewerId = viewer.userId;
    viewerToken = viewer.token;
    storeId = (await createStore("Feed Reels Store", ownerId)).id;

    const image = await prisma.post.create({
      data: {
        storeId,
        type: "image",
        caption: "image",
        thumbnailUrl: "",
        createdAt: new Date(base - 2000),
        media: { create: [{ url: "/media/posts/a.jpg", position: 0 }] },
      },
    });
    // thumbnailUrl "" is the common case for reels published from the web
    // composer (no thumbnail generator there) — the row must still serialise.
    const reel = await prisma.post.create({
      data: {
        storeId,
        type: "reel",
        caption: "reel",
        thumbnailUrl: "",
        createdAt: new Date(base - 1000),
        media: { create: [{ url: "/media/reels/x.mp4", position: 0 }] },
      },
    });
    const carousel = await prisma.post.create({
      data: {
        storeId,
        type: "carousel",
        caption: "carousel",
        thumbnailUrl: "",
        createdAt: new Date(base),
        media: {
          create: [
            { url: "/media/posts/b1.jpg", position: 0 },
            { url: "/media/posts/b2.jpg", position: 1 },
          ],
        },
      },
    });
    imageId = image.id;
    reelId = reel.id;
    carouselId = carousel.id;
  });

  afterAll(async () => {
    await cleanupStores([storeId]); // cascades the three posts + media
    await cleanupUsers([ownerId, viewerId]);
    await app.close();
  });

  async function feed(query: string): Promise<{ status: number; posts: Record<string, unknown>[] }> {
    const res = await app.inject({
      method: "GET",
      url: `/api/v1/feed${query}`,
      headers: authHeader(viewerToken),
    });
    return { status: res.statusCode, posts: res.statusCode === 200 ? res.json().posts : [] };
  }

  it("returns image, reel and carousel in one createdAt DESC stream", async () => {
    const { status, posts } = await feed("?limit=10");
    expect(status).toBe(200);

    const ids = posts.map((p) => p.id);
    expect(ids.slice(0, 3)).toEqual([carouselId, reelId, imageId]);

    const reel = posts[1];
    expect(reel.type).toBe("reel");
    expect(typeof reel.thumbnailUrl).toBe("string");
    expect((reel.media as { url: string }[])[0].url.endsWith(".mp4")).toBe(true);
    expect(typeof reel.likedByMe).toBe("boolean");
    expect(typeof reel.savedByMe).toBe("boolean");
  });

  it("honours ?type= as a single-type filter", async () => {
    const reels = await feed("?type=reel&limit=100");
    expect(reels.status).toBe(200);
    expect(reels.posts.every((p) => p.type === "reel")).toBe(true);
    const reelIds = reels.posts.map((p) => p.id);
    expect(reelIds).toContain(reelId);
    expect(reelIds).not.toContain(imageId);
    expect(reelIds).not.toContain(carouselId);

    const images = await feed("?type=image&limit=100");
    expect(images.status).toBe(200);
    expect(images.posts.every((p) => p.type === "image")).toBe(true);
    const imageIds = images.posts.map((p) => p.id);
    expect(imageIds).toContain(imageId);
    expect(imageIds).not.toContain(reelId);
    expect(imageIds).not.toContain(carouselId);
  });

  it("rejects an unknown ?type=", async () => {
    expect((await feed("?type=story")).status).toBe(400);
  });

  it("GET /reels is unchanged: reels only", async () => {
    const res = await app.inject({
      method: "GET",
      url: "/api/v1/reels?limit=100",
      headers: authHeader(viewerToken),
    });
    expect(res.statusCode).toBe(200);
    const posts = res.json().posts as Record<string, unknown>[];
    expect(posts.every((p) => p.type === "reel")).toBe(true);
    const ids = posts.map((p) => p.id);
    expect(ids).toContain(reelId);
    expect(ids).not.toContain(imageId);
    expect(ids).not.toContain(carouselId);
  });

  it("offset paging walks the mixed stream without overlap", async () => {
    const page0 = await feed("?limit=2&offset=0");
    const page1 = await feed("?limit=2&offset=2");
    expect(page0.status).toBe(200);
    expect(page1.status).toBe(200);

    const ids0 = page0.posts.map((p) => p.id);
    const ids1 = page1.posts.map((p) => p.id);
    expect(ids0).toEqual([carouselId, reelId]);
    expect(ids1[0]).toBe(imageId);
    expect(ids0.filter((id) => ids1.includes(id))).toEqual([]);
  });
});
