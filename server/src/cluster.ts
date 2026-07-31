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
