import cluster from "node:cluster";
import { availableParallelism } from "node:os";

import { config } from "./config.js";

// A Node process runs JavaScript on ONE core. Serving 100k daily active users
// from a single process leaves every other core idle and makes that one process
// both the throughput ceiling and a single point of failure.
//
// This forks one worker per core; they share the listening socket via the OS, so
// no proxy config or sticky sessions are needed. WebSockets work because each
// connection lives entirely on the worker that accepted it, and cross-worker
// realtime fan-out goes through Redis (realtime/bus.ts) — which is exactly why
// REDIS_URL becomes mandatory here. Without it, two users on different workers
// would never see each other's messages.
//
// Run with `npm run start:cluster`. `npm start` remains the single-process entry
// point, which is what the tests and local development use.
const workerCount = config.CLUSTER_WORKERS > 0 ? config.CLUSTER_WORKERS : availableParallelism();

/** Refuses to start if the workers would collectively ask MySQL for more
 * connections than it allows.
 *
 * Every worker owns an independent Prisma pool, so the connection count
 * multiplies by worker while MySQL's max_connections stays fixed. Load testing
 * hit this exactly: 8 workers on Prisma's default pool wanted 264 connections
 * against MariaDB's stock 151, and the overflow surfaced as scattered HTTP 500s
 * ("Too many database connections opened") on whichever requests happened to be
 * unlucky. Nothing in the logs pointed at the cause, and the failure only
 * appeared under concurrency — the worst combination to debug in production.
 *
 * Checking it here converts that into a boot failure with an actionable
 * message. Deliberately fatal rather than a warning: a server that starts and
 * then fails a fraction of requests is worse than one that refuses to start. */
async function assertConnectionBudgetFits(workers: number): Promise<void> {
  // Prisma's default when connection_limit is absent from the URL.
  const DEFAULT_POOL = availableParallelism() * 2 + 1;
  const limitParam = new URL(config.DATABASE_URL).searchParams.get("connection_limit");
  const perWorker = limitParam ? Number(limitParam) : DEFAULT_POOL;
  const wanted = perWorker * workers;

  const { prisma } = await import("./db.js");
  const rows = await prisma.$queryRaw<{ Value: string }[]>`SHOW VARIABLES LIKE 'max_connections'`;
  const maxConnections = Number(rows[0]?.Value ?? 0);
  await prisma.$disconnect();

  if (!maxConnections) {
    console.warn("[cluster] could not read MySQL max_connections — skipping budget check");
    return;
  }

  // Leave room for the web-admin panel's own pool, mysqldump during a backup,
  // and a human with a mysql shell open. A cluster sized to the exact ceiling
  // locks everyone else out at the worst possible moment.
  const RESERVED = 40;
  if (wanted + RESERVED > maxConnections) {
    const suggested = Math.max(5, Math.floor((maxConnections - RESERVED) / workers));
    console.error(
      `[cluster] connection budget does not fit:\n` +
        `  ${workers} workers x ${perWorker} connections = ${wanted}, plus ${RESERVED} reserved ` +
        `for the admin panel and maintenance,\n` +
        `  but MySQL max_connections = ${maxConnections}.\n` +
        `  Fix EITHER by raising max_connections in my.ini (recommended: ${wanted + RESERVED} or more),\n` +
        `  OR by setting connection_limit=${suggested} in DATABASE_URL,\n` +
        `  OR by lowering CLUSTER_WORKERS.\n` +
        `  Starting anyway would return sporadic 500s under load, not a clean failure.`
    );
    process.exit(1);
  }

  console.log(
    `[cluster] connection budget OK: ${workers} x ${perWorker} = ${wanted} ` +
      `(+${RESERVED} reserved) of ${maxConnections}`
  );
}

if (cluster.isPrimary) {
  if (!config.REDIS_URL) {
    // Failing loudly beats a deployment that appears healthy while silently
    // dropping realtime events for every user not on the publishing worker.
    console.error(
      "REDIS_URL is required in cluster mode: without it, realtime events do not " +
        "cross worker processes and users would silently miss messages. " +
        "Set REDIS_URL, or run single-process with `npm start`."
    );
    process.exit(1);
  }

  await assertConnectionBudgetFits(workerCount);

  console.log(`[cluster] primary ${process.pid} forking ${workerCount} workers`);
  for (let i = 0; i < workerCount; i++) cluster.fork();

  cluster.on("exit", (worker, code, signal) => {
    // Replace crashed workers so capacity self-heals. A worker that exits
    // cleanly during shutdown is not replaced (see the signal handler below).
    if (shuttingDown) return;
    console.error(`[cluster] worker ${worker.process.pid} died (${signal || code}) — restarting`);
    cluster.fork();
  });

  let shuttingDown = false;
  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      shuttingDown = true;
      for (const worker of Object.values(cluster.workers ?? {})) worker?.kill(sig);
    });
  }
} else {
  // Each worker is a normal single-process server.
  await import("./index.js");
}
