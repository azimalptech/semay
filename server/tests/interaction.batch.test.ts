import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { applyInteractionBatch } from "../src/posts/service.js";

// The mobile interaction buffer (30-min re-count window) flushes batched
// view/send/share increments instead of the old once-ever per-tap records.
// This proves the server just adds them: repeated flushes accumulate (a user
// CAN re-count after their local window), zero/omitted fields are skipped, and
// a stale/deleted postId never rejects the rest of the batch.
describe("interaction batch increments (buffer flush)", () => {
  let userId: string;
  let storeId: string;
  let postId: string;

  beforeAll(async () => {
    const phone = `+9939${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const user = await prisma.user.create({ data: { phone } });
    userId = user.id;
    const store = await prisma.store.create({ data: { name: "Batch Test Store", createdById: userId } });
    storeId = store.id;
    const post = await prisma.post.create({ data: { storeId, type: "image", caption: "" } });
    postId = post.id;
  });

  afterAll(async () => {
    await prisma.store.delete({ where: { id: storeId } }); // cascades post
    await prisma.user.delete({ where: { id: userId } });
  });

  it("accumulates increments across repeated flushes and skips zero fields", async () => {
    await applyInteractionBatch([{ postId, views: 1, sent: 1, shares: 1 }]);
    await applyInteractionBatch([{ postId, views: 1 }]); // same user re-counting a view next window
    await applyInteractionBatch([{ postId, views: 0, sent: 0, shares: 0 }]); // no-op

    const post = await prisma.post.findUniqueOrThrow({ where: { id: postId } });
    expect(post.viewsCount).toBe(2);
    expect(post.sentCount).toBe(1);
    expect(post.sharesCount).toBe(1);
  });

  it("ignores an unknown/deleted postId without failing the rest of the batch", async () => {
    await applyInteractionBatch([
      { postId: "00000000-0000-0000-0000-000000000000", views: 5 },
      { postId, shares: 3 },
    ]);

    const post = await prisma.post.findUniqueOrThrow({ where: { id: postId } });
    expect(post.sharesCount).toBe(4);
  });
});
