import Fastify from "fastify";

import { config } from "./config.js";
import { disconnectDb, prisma } from "./db.js";

// Phase 1 bootstrap. Feature routes (auth, users, stores, posts, chat, …) get
// registered here as each subsequent phase lands — see docs/07_MIGRATION.md.
const app = Fastify({
  logger: {
    level: "info",
    transport:
      process.env.NODE_ENV === "production"
        ? undefined
        : { target: "pino-pretty" },
  },
});

// Liveness/readiness — also the first thing to hit once the DB is provisioned,
// to confirm the API can actually reach MySQL.
app.get("/health", async () => {
  await prisma.$queryRaw`SELECT 1`;
  return { ok: true, ts: new Date().toISOString() };
});

async function start(): Promise<void> {
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
    await app.close();
    await disconnectDb();
    process.exit(0);
  });
}

void start();
