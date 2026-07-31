import { PrismaClient } from "@prisma/client";

// BigInt (post_media.id, messages.id, and other AUTO_INCREMENT BIGINT PKs) has
// no native JSON representation — JSON.stringify throws without this. Stringify
// rather than Number() since these can exceed Number.MAX_SAFE_INTEGER.
declare global {
  interface BigInt {
    toJSON(): string;
  }
}
BigInt.prototype.toJSON = function (this: bigint): string {
  return this.toString();
};

// Single shared Prisma client for the process. Fastify is single-instance here,
// so a module-level singleton is correct (no per-request instantiation).
export const prisma = new PrismaClient();

export async function disconnectDb(): Promise<void> {
  await prisma.$disconnect();
}

// Readiness probes can arrive from several proxies at once and much faster than
// the answer can change. Caching for a couple of seconds collapses a burst into
// a single round-trip, so probing can never itself exhaust the pool.
const READY_CACHE_MS = 2_000;
let readyCache: { at: number; ok: boolean } | undefined;
let readyInFlight: Promise<boolean> | undefined;

export async function isDbReady(): Promise<boolean> {
  const now = Date.now();
  if (readyCache && now - readyCache.at < READY_CACHE_MS) return readyCache.ok;
  // Collapse concurrent misses onto one query rather than one per caller.
  readyInFlight ??= (async () => {
    let ok = true;
    try {
      await prisma.$queryRaw`SELECT 1`;
    } catch {
      ok = false;
    }
    readyCache = { at: Date.now(), ok };
    readyInFlight = undefined;
    return ok;
  })();
  return readyInFlight;
}
