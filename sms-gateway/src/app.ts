import rateLimit from "@fastify/rate-limit";
import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";

import { config } from "./config.js";
import { prisma } from "./db.js";
import { deviceRoutes } from "./routes/device.js";
import { thirdPartyRoutes } from "./routes/thirdparty.js";

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.LOG_LEVEL },
    // Behind nginx on the same box; trust its forwarded headers so rate
    // limiting keys on the real client rather than on 127.0.0.1 for everyone.
    trustProxy: true,
  });

  await app.register(rateLimit, {
    max: 600,
    timeWindow: "1 minute",
    // The device WebSocket is a long-lived single connection per handset and
    // must never be rate limited off the air.
    allowList: () => false,
  });

  await app.register(websocket);

  // Liveness. No auth and no database touch — this is what a process monitor
  // polls, and making it hit MySQL would turn a slow database into a restart
  // loop.
  app.get("/health", async () => ({ ok: true, ts: new Date().toISOString() }));

  // Readiness: does the database actually answer? Separate from /health for
  // exactly the reason above.
  app.get("/health/ready", async (_req, reply) => {
    try {
      await prisma.$queryRaw`SELECT 1`;
      return { ok: true };
    } catch {
      return reply.code(503).send({ ok: false, error: "DATABASE_UNAVAILABLE" });
    }
  });

  await app.register(thirdPartyRoutes, { prefix: "/3rdparty/v1" });
  await app.register(deviceRoutes, { prefix: "/device" });

  return app;
}
