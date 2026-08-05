import { mkdir, unlink, utimes, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { runReapCycle } from "../src/maintenance.js";
import { MEDIA_DIR, publicUrlForKey } from "../src/media/storage.js";
import { createStore, createUserWithToken } from "./helpers.js";

// Nothing used to delete expired data, so stories (and their media files) and
// dead sessions grew without bound. These tests pin the reaper's two halves: it
// must remove what is genuinely dead, and must NOT touch anything still in use.
const log = {
  info: () => {},
  error: () => {},
} as unknown as Parameters<typeof runReapCycle>[0];

describe("maintenance reaper", () => {
  const userIds: string[] = [];
  const storeIds: string[] = [];
  const phones: string[] = [];

  beforeAll(async () => {
    await mkdir(path.join(MEDIA_DIR, "stories"), { recursive: true });
  });

  afterAll(async () => {
    await prisma.otpCode.deleteMany({ where: { phone: { in: phones } } });
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  it("deletes expired stories and their media files, keeping live ones intact", async () => {
    const admin = await createUserWithToken("admin");
    userIds.push(admin.userId);
    const store = await createStore("Reaper Store", admin.userId);
    storeIds.push(store.id);

    // Two real files on disk, one behind an expired story and one behind a live one.
    const expiredKey = `stories/reaper-expired-${Date.now()}.jpg`;
    const liveKey = `stories/reaper-live-${Date.now()}.jpg`;
    await writeFile(path.join(MEDIA_DIR, expiredKey), "expired-bytes");
    await writeFile(path.join(MEDIA_DIR, liveKey), "live-bytes");

    const expired = await prisma.story.create({
      data: {
        storeId: store.id,
        mediaUrl: publicUrlForKey(expiredKey),
        mediaType: "image",
        // Well past the reaper's grace window.
        expiresAt: new Date(Date.now() - 6 * 60 * 60 * 1000),
      },
    });
    const live = await prisma.story.create({
      data: {
        storeId: store.id,
        mediaUrl: publicUrlForKey(liveKey),
        mediaType: "image",
        expiresAt: new Date(Date.now() + 12 * 60 * 60 * 1000),
      },
    });

    await runReapCycle(log);

    expect(await prisma.story.findUnique({ where: { id: expired.id } })).toBeNull();
    expect(await prisma.story.findUnique({ where: { id: live.id } })).not.toBeNull();

    // The whole point: the bytes are gone too, not just the row.
    expect(existsSync(path.join(MEDIA_DIR, expiredKey))).toBe(false);
    expect(existsSync(path.join(MEDIA_DIR, liveKey))).toBe(true);
  });

  it("does not reap a story that only just expired (grace window)", async () => {
    const admin = await createUserWithToken("admin");
    userIds.push(admin.userId);
    const store = await createStore("Grace Store", admin.userId);
    storeIds.push(store.id);

    const justExpired = await prisma.story.create({
      data: {
        storeId: store.id,
        mediaUrl: publicUrlForKey(`stories/grace-${Date.now()}.jpg`),
        mediaType: "image",
        expiresAt: new Date(Date.now() - 60_000), // a minute ago
      },
    });

    await runReapCycle(log);

    // Still present — a viewer mid-playback when the clock rolls over must not
    // have the story deleted out from under them.
    expect(await prisma.story.findUnique({ where: { id: justExpired.id } })).not.toBeNull();
    await prisma.story.delete({ where: { id: justExpired.id } });
  });

  it("reaps expired sessions but keeps live ones", async () => {
    const user = await createUserWithToken();
    userIds.push(user.userId);

    const dead = await prisma.session.create({
      data: {
        userId: user.userId,
        tokenHash: `dead-${Date.now()}`,
        expiresAt: new Date(Date.now() - 1000),
      },
    });
    const alive = await prisma.session.create({
      data: {
        userId: user.userId,
        tokenHash: `alive-${Date.now()}`,
        expiresAt: new Date(Date.now() + 86_400_000),
      },
    });

    await runReapCycle(log);

    expect(await prisma.session.findUnique({ where: { id: dead.id } })).toBeNull();
    expect(await prisma.session.findUnique({ where: { id: alive.id } })).not.toBeNull();
  });

  // Regression: the lease was originally MySQL GET_LOCK, which is session-scoped
  // while Prisma runs each query on an arbitrary pooled connection — RELEASE_LOCK
  // landed on a different connection, silently failed, and the lock stayed held
  // forever. The reaper ran exactly once per deploy and then never again. Running
  // consecutive cycles is what catches that.
  it("releases its lease so later cycles still run", async () => {
    const admin = await createUserWithToken("admin");
    userIds.push(admin.userId);
    const store = await createStore("Lease Store", admin.userId);
    storeIds.push(store.id);

    await runReapCycle(log);

    // A story that only becomes reapable for the SECOND cycle. If the lease
    // leaked, this cycle would no-op and the story would survive.
    const stale = await prisma.story.create({
      data: {
        storeId: store.id,
        mediaUrl: publicUrlForKey(`stories/lease-${Date.now()}.jpg`),
        mediaType: "image",
        expiresAt: new Date(Date.now() - 6 * 60 * 60 * 1000),
      },
    });

    await runReapCycle(log);

    expect(await prisma.story.findUnique({ where: { id: stale.id } })).toBeNull();
  });

  // Deletion paths clean up their own files, but only for deletions made since
  // that existed and only if the process survived to finish. This is the
  // backstop — without it the dev media folder had 26 files against ~1 live
  // reference.
  it("deletes unreferenced media, but never a referenced or a freshly-uploaded file", async () => {
    const admin = await createUserWithToken("admin");
    userIds.push(admin.userId);
    const store = await createStore("Orphan Store", admin.userId);
    storeIds.push(store.id);

    const orphanKey = `posts/orphan-${Date.now()}.jpg`;
    const liveKey = `posts/live-${Date.now()}.jpg`;
    const freshKey = `posts/fresh-${Date.now()}.jpg`;
    for (const k of [orphanKey, liveKey, freshKey]) {
      await writeFile(path.join(MEDIA_DIR, k), "bytes");
    }

    // Referenced by a real post row.
    await prisma.post.create({
      data: {
        storeId: store.id,
        type: "image",
        caption: "",
        thumbnailUrl: "",
        media: { create: [{ url: publicUrlForKey(liveKey), position: 0 }] },
      },
    });

    // Age the orphan past the grace window; leave `fresh` with a current mtime
    // so it stands in for an upload whose row hasn't been written yet.
    const old = new Date(Date.now() - 48 * 60 * 60 * 1000);
    await utimes(path.join(MEDIA_DIR, orphanKey), old, old);

    await runReapCycle(log);

    expect(existsSync(path.join(MEDIA_DIR, orphanKey))).toBe(false);
    expect(existsSync(path.join(MEDIA_DIR, liveKey))).toBe(true);
    expect(existsSync(path.join(MEDIA_DIR, freshKey))).toBe(true);

    await unlink(path.join(MEDIA_DIR, liveKey)).catch(() => {});
    await unlink(path.join(MEDIA_DIR, freshKey)).catch(() => {});
  });

  it("never reaps an OTP row that is still serving a lockout", async () => {
    const lockedPhone = `+99361${Math.floor(100000 + Math.random() * 899999)}`;
    const stalePhone = `+99362${Math.floor(100000 + Math.random() * 899999)}`;
    phones.push(lockedPhone, stalePhone);

    // Expired code, but the phone is still locked out for brute-forcing. Deleting
    // this row would reset the attempts counter and hand the attacker a fresh
    // set of guesses — the one case the reaper must leave alone.
    await prisma.otpCode.create({
      data: {
        phone: lockedPhone,
        code: "111111",
        expiresAt: new Date(Date.now() - 60_000),
        lastSentAt: new Date(Date.now() - 60_000),
        attempts: 5,
        lockedUntil: new Date(Date.now() + 30 * 60_000),
      },
    });
    await prisma.otpCode.create({
      data: {
        phone: stalePhone,
        code: "222222",
        expiresAt: new Date(Date.now() - 60_000),
        lastSentAt: new Date(Date.now() - 60_000),
        attempts: 1,
      },
    });

    await runReapCycle(log);

    expect(await prisma.otpCode.findUnique({ where: { phone: lockedPhone } })).not.toBeNull();
    expect(await prisma.otpCode.findUnique({ where: { phone: stalePhone } })).toBeNull();
  });
});
