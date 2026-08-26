import { buildApp } from "./app.js";
import { config } from "./config.js";
import { prisma } from "./db.js";
import { dispatchPending, reclaimStalled } from "./dispatch.js";

const SWEEP_INTERVAL_MS = 10_000;

async function main(): Promise<void> {
  const app = await buildApp();

  // The sweep is what makes the system self-healing: it reclaims messages
  // assigned to handsets that went away, and re-drives the queue when a SIM's
  // pacing window opens. Without it, a message assigned to a phone that lost
  // signal would sit Assigned forever.
  const sweep = setInterval(() => {
    void reclaimStalled()
      .then(() => dispatchPending())
      .catch((err) => app.log.error({ err }, "sweep failed"));
  }, SWEEP_INTERVAL_MS);

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info({ signal }, "shutting down");
    clearInterval(sweep);
    await app.close();
    await prisma.$disconnect();
    process.exit(0);
  };
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));

  await app.listen({ port: config.PORT, host: "0.0.0.0" });
  app.log.info(`sms-gateway listening on :${config.PORT}`);
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
