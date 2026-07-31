import { buildApp } from "./app.js";
import { config } from "./config.js";
import { disconnectDb } from "./db.js";
import { getFcmDisabledReason } from "./lib/firebaseAdmin.js";
import { startMaintenance } from "./maintenance.js";
import { closeBus, isDistributed } from "./realtime/bus.js";

// buildApp() creates the media dir before mounting the static server.
const app = await buildApp();
// Safe to start in every process: a MySQL advisory lock ensures only one actually
// reaps per tick, across all workers and machines.
const stopMaintenance = startMaintenance(app.log);

async function start(): Promise<void> {
  // Surface a push-less deployment at boot rather than letting it be discovered
  // when a notification never arrives.
  const fcmDisabled = getFcmDisabledReason();
  if (fcmDisabled) {
    app.log.warn({ reason: fcmDisabled }, "FCM push is DISABLED");
  }
  // A multi-process deployment without Redis appears healthy while silently
  // dropping realtime events across processes — worth stating explicitly at boot.
  app.log.info(
    { distributed: isDistributed() },
    isDistributed()
      ? "realtime: Redis pub-sub (safe for multiple processes)"
      : "realtime: in-process only — set REDIS_URL before running more than one process"
  );
  try {
    await app.listen({ port: config.PORT, host: "0.0.0.0" });
  } catch (err) {
    app.log.error(err);
    await disconnectDb();
    process.exit(1);
  }
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, async () => {
    stopMaintenance();
    await app.close();
    await closeBus();
    await disconnectDb();
    process.exit(0);
  });
}

void start();
