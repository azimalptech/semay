import { PrismaClient } from "@prisma/client";

/** The name helpers.ts stamps on every fixture row. Matching on it means this
 * sweep can never touch a real account. */
const FIXTURE_NAME = "__TEST_FIXTURE__";

/** No fixture a live run owns is older than this, so a row older than it is
 * certainly leaked and certainly nobody's. BOTH sweeps are scoped to it.
 *
 * Without the cutoff a sweep deleted EVERY fixture row on the dev database,
 * including those of a `vitest run` already in progress in another terminal or
 * another agent's session — the victim then failed with P2025 out of
 * getClaimsForUser, which reads exactly like a code regression and is not one.
 * tests/chat.liveness.test.ts is the file that made it visible: its fixtures
 * live through five describe blocks for ~19 s, the longest in the suite.
 *
 * The post-run sweep used to skip the cutoff, on the reasoning that by then
 * this process owns the run and everything left is leaked. That is false
 * whenever two runs overlap — which is the very condition the cutoff was added
 * for. A SHORT run finishing while a LONG one is mid-flight deleted the long
 * run's users (and cascaded through their stores to its chats and messages),
 * and chat.liveness.test.ts, the longest fixture holder in the suite, ate it:
 * reproduced by starting `vitest run tests/chat.liveness.test.ts` and, six
 * seconds later, `vitest run tests/media.serving.test.ts` — the short run's
 * teardown printed "removed 1 leaked fixture account(s)" and the long run
 * failed 4 of 6 with P2025.
 *
 * The cost of scoping it is that a row THIS run leaks is not collected until
 * some later run's setup sweep, ten minutes on. That is a lag, not a leak —
 * and the one file that leaked every run (media.serving.test.ts, which
 * collected user ids into an array it never cleaned up) now cleans up after
 * itself, so the sweep is a backstop again rather than routine. */
const MAX_RUN_AGE_MS = 10 * 60_000;

async function sweep(label: string): Promise<void> {
  const prisma = new PrismaClient();
  try {
    const users = await prisma.user.findMany({
      where: { name: FIXTURE_NAME, createdAt: { lt: new Date(Date.now() - MAX_RUN_AGE_MS) } },
      select: { id: true },
    });
    if (users.length === 0) return;
    const userIds = users.map((u) => u.id);

    // Stores first: they cascade to posts, chats and messages, which would
    // otherwise still hold FKs onto the users below. Orders use a RESTRICT FK
    // on userId, so anything a fixture "bought" has to go explicitly.
    await prisma.store.deleteMany({ where: { createdById: { in: userIds } } });
    await prisma.order.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.order.deleteMany({ where: { adminId: { in: userIds } } });
    const { count } = await prisma.user.deleteMany({ where: { id: { in: userIds } } });

    if (count > 0) {
      console.log(`[test ${label}] removed ${count} leaked fixture account(s)`);
    }
  } finally {
    await prisma.$disconnect();
  }
}

/** Runs before the suite — clears fixtures a PREVIOUS run leaked behind, and
 * only those: rows younger than MAX_RUN_AGE_MS may belong to a run happening
 * right now in another terminal. */
export async function setup(): Promise<void> {
  await sweep("setup");
}

/** Runs after the suite — a second pass at rows old enough to be nobody's.
 *
 * Per-file afterAll blocks are best-effort: they don't run when a file throws
 * during setup, a worker is killed, or the run is interrupted. The dev database
 * had accumulated 11 orphaned accounts exactly that way — 10 of them
 * superadmins. This pair collects them, bounded by MAX_RUN_AGE_MS on BOTH ends
 * so it can never delete a concurrent run's live fixtures (see there).
 */
export async function teardown(): Promise<void> {
  await sweep("teardown");
}
