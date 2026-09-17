import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { createStory } from "../src/stories/service.js";
import {
  authHeader,
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  type App,
} from "./helpers.js";

// The product rule for BOTH story rings (the home bar and, since this pass,
// the store profile header) is: gradient while an active story is unseen,
// muted once they have all been watched.
//
// `recordStoryView` used to stamp user_story_seen for the whole store on every
// slide, and the viewer fires it per slide — so watching 1 of 3 made
// GET /stories/rings answer `seen: true` and both rings went muted with two
// stories still unwatched. "Watched to the end" has its own signal:
// POST /stores/:storeId/story-seen, which the viewer sends on the last slide.
describe("story rings: seen means watched to the end", () => {
  let app: App;
  let viewerId: string;
  let viewerToken: string;
  let ownerId: string;
  let storeId: string;
  let firstStoryId: string;
  let lastStoryId: string;

  beforeAll(async () => {
    app = await buildApp();
    ({ userId: viewerId, token: viewerToken } = await createUserWithToken("user"));
    ({ userId: ownerId } = await createUserWithToken("admin"));
    storeId = (await createStore("Seen Rule Store", ownerId)).id;
    firstStoryId = (await createStory(storeId, "/media/stories/a.jpg", "image")).id;
    lastStoryId = (await createStory(storeId, "/media/stories/b.jpg", "image")).id;
  });

  afterAll(async () => {
    await app.close();
    await prisma.userStorySeen.deleteMany({ where: { storeId } });
    await prisma.story.deleteMany({ where: { storeId } });
    await cleanupStores([storeId]);
    await cleanupUsers([viewerId, ownerId]);
  });

  const ring = async () => {
    const res = await app.inject({
      method: "GET",
      url: "/api/v1/stories/rings",
      headers: authHeader(viewerToken),
    });
    expect(res.statusCode).toBe(200);
    return (res.json().rings as Array<{ storeId: string; hasStories: boolean; seen: boolean }>).find(
      (r) => r.storeId === storeId
    );
  };

  const view = async (storyId: string) => {
    const res = await app.inject({
      method: "POST",
      url: `/api/v1/stories/${storyId}/view`,
      headers: authHeader(viewerToken),
    });
    expect(res.statusCode).toBe(200);
  };

  it("stays unseen after 1 of 2 slides is viewed", async () => {
    expect(await ring()).toMatchObject({ hasStories: true, seen: false });

    await view(firstStoryId);

    expect(await ring()).toMatchObject({ hasStories: true, seen: false });
    // The view itself is still recorded — "seen by N" must not regress.
    expect(await prisma.storyView.count({ where: { storyId: firstStoryId } })).toBe(1);
  });

  it("goes seen only once the viewer reports the last slide", async () => {
    await view(lastStoryId);
    expect(await ring()).toMatchObject({ seen: false });

    const res = await app.inject({
      method: "POST",
      url: `/api/v1/stores/${storeId}/story-seen`,
      headers: authHeader(viewerToken),
    });
    expect(res.statusCode).toBe(200);

    expect(await ring()).toMatchObject({ hasStories: true, seen: true });
  });

  it("a new story after that re-lights the ring", async () => {
    // getStoryRings compares seenAt against the LATEST active story, so a
    // story published after the mark must read unseen again.
    await new Promise((r) => setTimeout(r, 1100));
    const fresh = await createStory(storeId, "/media/stories/c.jpg", "image");
    expect(await ring()).toMatchObject({ hasStories: true, seen: false });
    await prisma.story.delete({ where: { id: fresh.id } });
  });
});
