import { buildApp } from "./app.js";
import { config } from "./config.js";
import { disconnectDb } from "./db.js";
import { getFcmDisabledReason, getFcmIdentity } from "./lib/firebaseAdmin.js";
import { startMaintenance } from "./maintenance.js";
import { bindPushLogger } from "./notifications/push.js";
import { bindBusLogger, closeBus, verifyBusAtBoot } from "./realtime/bus.js";

// buildApp() creates the media dir before mounting the static server.
const app = await buildApp();
// Safe to start in every process: a MySQL advisory lock ensures only one actually
// reaps per tick, across all workers and machines.
const stopMaintenance = startMaintenance(app.log);

async function start(): Promise<void> {
  // Surface a push-less deployment at boot rather than letting it be discovered
  // when a notification never arrives — and keep surfacing it: with the logger
  // bound, every push the server then skips is a warn line in the same log
  // ("push skipped: FCM disabled"), not a silent {sent: 0}.
  bindPushLogger(app.log);
  const fcmDisabled = getFcmDisabledReason();
  if (fcmDisabled) {
    app.log.warn({ reason: fcmDisabled }, "FCM push is DISABLED");
  } else {
    // Which project and which key is sending, so it can be matched against the
    // project the app was built for (mobile/lib/core/firebase_options.dart).
    app.log.info({ fcm: getFcmIdentity() }, "FCM push enabled");
  }
  // The bus states its mode at boot and, with the logger bound, every Redis
  // error and reconnect after it. A set-but-unreachable REDIS_URL used to
  // produce the same "Redis pub-sub" line as a working one: the process
  // boots regardless (in-process delivery — complete for one process), the
  // verdict is an error-level line naming the host, and /health/ready carries
  // it as bus.ready=false. Cluster mode refuses to fork instead (cluster.ts).
  bindBusLogger(app.log);
  // Kicked off, deliberately NOT awaited. The probe waits up to 5 s for Redis,
  // and awaiting it here put those 5 s in front of app.listen() on every
  // restart whenever Redis was slow or unreachable — measured on a blackholed
  // REDIS_URL: the "Server listening" line landed 5.03 s after boot, purely
  // waiting on a dependency this process does not need in order to answer
  // anything. A Redis outage must not also be a deploy outage, and nothing in
  // the verdict gates serving: the process boots degraded either way and
  // publish() always delivers to its own sockets first. The verdict is a log
  // line and /health/realtime, both of which arrive when they arrive.
  //
  // cluster.ts's primary still AWAITS it — there it is the fail-closed gate
  // that refuses to fork, and that primary serves no traffic.
  void verifyBusAtBoot().catch((err: unknown) => app.log.error({ err }, "realtime: boot probe"));
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
