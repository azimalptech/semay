import { PrismaClient } from "@prisma/client";

/** The name helpers.ts stamps on every fixture row. Matching on it means this
 * sweep can never touch a real account. */
const FIXTURE_NAME = "__TEST_FIXTURE__";

async function sweep(label: string): Promise<void> {
  const prisma = new PrismaClient();
  try {
    const users = await prisma.user.findMany({
      where: { name: FIXTURE_NAME },
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

/** Runs before the suite — clears fixtures a PREVIOUS run leaked behind. */
export async function setup(): Promise<void> {
  await sweep("setup");
}

/** Runs after the suite — clears anything this run leaked.
 *
 * Per-file afterAll blocks are best-effort: they don't run when a file throws
 * during setup, a worker is killed, or the run is interrupted. The dev database
 * had accumulated 11 orphaned accounts exactly that way — 10 of them
 * superadmins. This pair makes leakage impossible rather than merely unlikely.
 */
export async function teardown(): Promise<void> {
  await sweep("teardown");
}
