import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    setupFiles: ["./tests/setup.ts"],
    // Backstop for fixture rows whose per-file afterAll never ran (setup threw,
    // worker killed, run interrupted) — see tests/globalTeardown.ts.
    globalSetup: ["./tests/globalTeardown.ts"],
    testTimeout: 15000,
    // Vitest sizes its worker pool from the CPU count, but the resource this
    // suite actually contends for is ONE MariaDB and one Prisma connection pool
    // per worker (DATABASE_URL carries connection_limit=15). On a 16-core box
    // that is 15 pools of 15 against a single server, and chat.liveness.test.ts
    // alone stands up six more module graphs — six more pools — inside its own
    // worker. The result was a gate that could not be trusted: whole files lost
    // to "Transaction API error: Unable to start a transaction in the given
    // time", in a different file each run, because Prisma's 2 s maxWait expired
    // while the CPU was oversubscribed. Reproduced deliberately (12 busy
    // threads alongside the run): 3 files / 5 tests red, all of them that
    // error.
    //
    // The production side of that is fixed where it belongs — src/lib/
    // withRetry.ts now retries a transaction the pool refused to start, since
    // no statement of it ever ran. This cap is the other half: the suite stops
    // manufacturing a level of contention no deployment produces. It costs
    // nothing in wall-clock, because the run is bounded by its longest FILE
    // (chat.liveness.test.ts, ~29 s), not by how many run at once.
    poolOptions: { threads: { maxThreads: 4 } },
  },
});
