import type { FastifyBaseLogger } from "fastify";

import { stat, unlink } from "node:fs/promises";
import path from "node:path";

import { prisma } from "./db.js";
import {
  deleteMediaByUrls,
  keyForPublicUrl,
  listMediaFiles,
  MEDIA_DIR,
} from "./media/storage.js";

// Nothing in this codebase ever removed expired data, which meant three tables
// (and the media folder) grew without bound:
//
//   stories   — every story ever posted stayed forever, along with its image or
//               video file, even though each one is only visible for 24h. This is
//               the highest-churn media in the app and by far the biggest leak.
//   sessions  — one row per login, expiring after 30 days but never deleted.
//   otp_codes — one row per phone; bounded, but stale rows serve no purpose.
//
// The Firestore design had a scheduled Cloud Function for this (see
// docs/02_DATA_MODEL.md); the migration replaced the function but never the
// schedule. This is that replacement.
const REAP_INTERVAL_MS = 60 * 60 * 1000; // hourly
const REAP_BATCH = 500; // bounded so one tick can never hold locks for long

// Expired stories are deleted well after they stop being visible, so a viewer
// mid-playback when the clock rolls over is never cut off by the reaper.
const STORY_GRACE_MS = 60 * 60 * 1000;

// Exactly one reaper runs at a time across every worker process AND every machine
// pointed at this database — more correct than "only run on worker 1", which
// breaks the moment there are two hosts.
//
// Implemented as a lease row, NOT MySQL's GET_LOCK: that lock is owned by the
// *session*, but Prisma runs each query on an arbitrary pooled connection, so
// RELEASE_LOCK would usually execute on a different connection than GET_LOCK,
// silently fail, and leave the lock held by a pooled connection that never
// closes — the reaper would run once and then never again.
const REAPER_LEASE = "reaper";
// Long enough to cover a realistic cycle; if a holder crashes the lease simply
// lapses. Reaping is idempotent, so an overlap after expiry is harmless.
const LEASE_MS = 15 * 60 * 1000;

/** Atomically takes the lease. The conditional UPDATE is the whole mechanism:
 * only one caller can match `lockedUntil <= NOW()` and move it forward. */
async function acquireLease(): Promise<boolean> {
  const now = new Date();
  const until = new Date(now.getTime() + LEASE_MS);

  // Ensure the row exists without stealing a live lease.
  try {
    await prisma.maintenanceLease.create({
      data: { name: REAPER_LEASE, lockedUntil: until },
    });
    return true; // first ever run: creating the row *is* acquiring it
  } catch {
    // Already exists — fall through to the conditional claim.
  }

  const { count } = await prisma.maintenanceLease.updateMany({
    where: { name: REAPER_LEASE, lockedUntil: { lte: now } },
    data: { lockedUntil: until },
  });
  return count === 1;
}

/** Ends the lease early so the next scheduled tick isn't blocked by it. */
async function releaseLease(): Promise<void> {
  await prisma.maintenanceLease
    .update({ where: { name: REAPER_LEASE }, data: { lockedUntil: new Date() } })
    .catch(() => {
      /* expiry is the backstop — a failed release just delays the next cycle */
    });
}

async function reapExpiredStories(log: FastifyBaseLogger): Promise<void> {
  const cutoff = new Date(Date.now() - STORY_GRACE_MS);
  // Loop in batches: a store that posted for a year shouldn't need a single
  // enormous DELETE, and each batch commits independently.
  for (;;) {
    const batch = await prisma.story.findMany({
      where: { expiresAt: { lte: cutoff } },
      select: { id: true, mediaUrl: true },
      take: REAP_BATCH,
    });
    if (batch.length === 0) return;

    await prisma.story.deleteMany({ where: { id: { in: batch.map((s) => s.id) } } });
    // Files only after the rows are gone — the DB stays the source of truth, and
    // a crash in between leaves a recoverable stray file rather than a story row
    // pointing at nothing.
    const removed = await deleteMediaByUrls(batch.map((s) => s.mediaUrl));
    log.info({ stories: batch.length, files: removed }, "reaped expired stories");

    if (batch.length < REAP_BATCH) return;
  }
}

async function reapDeadSessions(log: FastifyBaseLogger): Promise<void> {
  // Revoked rows are kept a while so a replayed old refresh token still hits an
  // explicit "revoked" row (401) rather than silently missing.
  const revokedCutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
  const { count } = await prisma.session.deleteMany({
    where: {
      OR: [{ expiresAt: { lte: new Date() } }, { revokedAt: { lte: revokedCutoff } }],
    },
  });
  if (count > 0) log.info({ sessions: count }, "reaped dead sessions");
}

async function reapExpiredOtps(log: FastifyBaseLogger): Promise<void> {
  const now = new Date();
  const { count } = await prisma.otpCode.deleteMany({
    // Never delete a row still serving a lockout — that would hand a brute-force
    // attacker a free reset of the attempts counter.
    where: {
      expiresAt: { lte: now },
      OR: [{ lockedUntil: null }, { lockedUntil: { lte: now } }],
    },
  });
  if (count > 0) log.info({ otpCodes: count }, "reaped expired OTP codes");
}

/** Removes media files on disk that nothing in the database references any more.
 *
 * Deletion paths clean up their own files as they go, but only for deletions
 * made SINCE that was implemented, and only when the process survived long
 * enough to finish. Anything orphaned before then — or by a crash between the
 * DB commit and the unlink — is invisible to the database and would sit on disk
 * forever. This is the backstop that bounds it.
 *
 * A file is only removed once it is BOTH unreferenced and older than the grace
 * window: an upload lands on disk before the row that points at it is written,
 * so a newly-uploaded file is legitimately unreferenced for a short time. */
const ORPHAN_GRACE_MS = 24 * 60 * 60 * 1000;

async function reapOrphanedMedia(log: FastifyBaseLogger): Promise<void> {
  const referenced = new Set<string>();
  const add = (url: string | null | undefined) => {
    const key = keyForPublicUrl(url ?? "");
    if (key) referenced.add(key.replace(/\\/g, "/"));
  };

  for (const m of await prisma.postMedia.findMany({ select: { url: true } })) add(m.url);
  for (const p of await prisma.post.findMany({ select: { thumbnailUrl: true } })) add(p.thumbnailUrl);
  for (const s of await prisma.story.findMany({ select: { mediaUrl: true } })) add(s.mediaUrl);
  for (const u of await prisma.user.findMany({ select: { avatarUrl: true } })) add(u.avatarUrl);
  for (const s of await prisma.store.findMany({
    select: { avatarUrl: true, coverUrl: true, campaignImageUrl: true },
  })) {
    add(s.avatarUrl);
    add(s.coverUrl);
    add(s.campaignImageUrl);
  }
  for (const m of await prisma.message.findMany({
    where: { mediaUrl: { not: null } },
    select: { mediaUrl: true },
  })) {
    add(m.mediaUrl);
  }

  const cutoff = Date.now() - ORPHAN_GRACE_MS;
  let removed = 0;
  for (const abs of await listMediaFiles()) {
    const key = path.relative(MEDIA_DIR, abs).replace(/\\/g, "/");
    if (referenced.has(key)) continue;
    try {
      const info = await stat(abs);
      if (info.mtimeMs > cutoff) continue; // still inside the upload grace window
      await unlink(abs);
      removed++;
    } catch {
      /* already gone or unreadable — nothing to do */
    }
  }
  if (removed > 0) log.info({ files: removed }, "reaped orphaned media files");
}

/** One full reap pass, guarded by the lease. Exported for tests so they exercise
 * the same code path the scheduler runs, lease included. */
export async function runReapCycle(log: FastifyBaseLogger): Promise<void> {
  if (!(await acquireLease())) return; // another process holds it this tick

  try {
    await reapExpiredStories(log);
    await reapDeadSessions(log);
    await reapExpiredOtps(log);
    await reapOrphanedMedia(log);
  } finally {
    await releaseLease();
  }
}

/** Starts the periodic reaper. Returns a stop function for graceful shutdown. */
export function startMaintenance(log: FastifyBaseLogger): () => void {
  const tick = (): void => {
    runReapCycle(log).catch((err) => {
      // A failed cycle is not fatal — the next tick retries. Never let it reject
      // an unhandled promise and take the process down.
      log.error({ err }, "maintenance cycle failed");
    });
  };

  // First pass shortly after boot rather than immediately, so it never competes
  // with startup traffic, then hourly.
  const initial = setTimeout(tick, 60_000);
  const interval = setInterval(tick, REAP_INTERVAL_MS);
  // Timers must not by themselves keep the process alive at shutdown.
  initial.unref();
  interval.unref();

  return () => {
    clearTimeout(initial);
    clearInterval(interval);
  };
}
