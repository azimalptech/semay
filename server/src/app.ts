import fastifyStatic from "@fastify/static";
import helmet from "@fastify/helmet";
import rateLimit from "@fastify/rate-limit";
import websocketPlugin from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";

import { config } from "./config.js";
import { isDbReady } from "./db.js";
import { registerErrorHandler } from "./lib/errors.js";
import { logTargets } from "./lib/logging.js";
import { ensureMediaDir, MEDIA_DIR } from "./media/storage.js";
import { authRoutes } from "./auth/routes.js";
import { userRoutes } from "./users/routes.js";
import { storeRoutes } from "./stores/routes.js";
import { postRoutes } from "./posts/routes.js";
import { storyRoutes } from "./stories/routes.js";
import { mediaRoutes } from "./media/routes.js";
import { chatRoutes } from "./chats/routes.js";
import { orderRoutes } from "./orders/routes.js";
import { notificationRoutes } from "./notifications/routes.js";
import { quickReplyRoutes } from "./quickReplies/routes.js";
import { notificationRequestRoutes } from "./notificationRequests/routes.js";
import { realtimeGateway } from "./realtime/gateway.js";

// Split from index.ts so tests can `buildApp()` + `app.inject()` against a real
// route tree/DB without opening a TCP listener — see tests/authz.*.test.ts.
export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    // Behind Caddy/Nginx in production — trust X-Forwarded-* so req.ip is the
    // real client IP (correct logs + per-client rate limiting), not the proxy's.
    trustProxy: true,
    logger: {
      level: process.env.NODE_ENV === "test" ? "silent" : config.LOG_LEVEL,
      transport: process.env.NODE_ENV === "test" ? undefined : { targets: logTargets() },
      serializers: {
        // The WebSocket handshake carries the access token in its query string
        // (a client cannot set headers on a browser-style upgrade), and the
        // default serializer wrote the full URL — token included — to the
        // rotating disk log on every connect. Everything else the default
        // serializer logs is kept.
        req(request: { method?: string; url?: string; hostname?: string; ip?: string }) {
          return {
            method: request.method,
            url: request.url?.replace(/([?&]token=)[^&]+/, "$1[redacted]"),
            hostname: request.hostname,
            remoteAddress: request.ip,
          };
        },
      },
    },
  });

  registerErrorHandler(app);

  // Liveness — registered BEFORE the rate limiter so proxy health probes (which
  // can be frequent) are never throttled. Deliberately does NOT touch the DB:
  // this endpoint is public and unthrottled, so a DB round-trip here would let
  // anyone drain the Prisma connection pool by hammering it.
  app.get("/health", async () => ({ ok: true, ts: new Date().toISOString() }));

  // Readiness — the DB check, kept separate and behind the rate limiter below.
  // Result is cached briefly so a burst of probes collapses into one query.
  app.get("/health/ready", async (_req, reply) => {
    const ready = await isDbReady();
    return reply.code(ready ? 200 : 503).send({ ok: ready });
  });

  // Security headers on every response (safe defaults for a JSON API).
  await app.register(helmet);

  // Global per-IP request cap — a backstop against a single runaway/abusive
  // client, deliberately generous so carrier-NAT'd real users aren't caught
  // (see config.ts). Skipped in tests (app.inject has no real IP and the authz
  // matrix fires many requests fast). Auth brute-force is separately bounded by
  // the per-phone OTP cooldown/lockout. Registered here so it covers every API
  // route below but not /health above.
  if (process.env.NODE_ENV !== "test") {
    await app.register(rateLimit, {
      max: config.RATE_LIMIT_MAX_PER_MIN,
      timeWindow: "1 minute",
    });
  }

  // Serve the local public media folder (replaces MinIO's public bucket).
  // Public reads with HTTP range support (video seeking); writes go through the
  // signed PUT /api/v1/media/blob/* in media/routes.ts. In production this can
  // instead be fronted by a Caddy/Nginx file_server rooted at MEDIA_DIR for
  // performance — the API serving it is fine for dev and modest load.
  // Created here (before the static mount, which requires the dir to exist).
  await ensureMediaDir();
  await app.register(fastifyStatic, {
    root: MEDIA_DIR,
    prefix: "/media/",
    index: false,
    // Defense in depth behind media/routes.ts's extension allowlist. These files
    // are user-supplied bytes served from the API's own origin, so if anything
    // ever did land here with an active content type, these headers stop it
    // executing: no MIME sniffing, and a CSP that forbids scripts entirely.
    // Receives a FastifyReply, so use .header() — NOT the raw response's
    // .setHeader(), which does not exist here and throws inside the send stream,
    // crashing the process on the very first media request.
    setHeaders(res) {
      res.header("X-Content-Type-Options", "nosniff");
      res.header("Content-Security-Policy", "default-src 'none'; sandbox");
      // Immutable: keys are content-addressed by UUID and never rewritten, so a
      // long cache is safe and keeps media serving off the app entirely.
      res.header("Cache-Control", "public, max-age=31536000, immutable");
    },
  });

  // maxPayload: the largest legitimate client frame is a subscribe carrying a
  // channel name (< 200 bytes). ws's default is 100 MiB, and the gateway
  // buffers + JSON.parses every frame synchronously for any authenticated
  // client — without a cap one user could stall the event loop or drive the
  // worker to OOM. ws closes an oversized sender with 1009 before buffering.
  await app.register(websocketPlugin, { options: { maxPayload: 4 * 1024 } });

  await app.register(authRoutes, { prefix: "/api/v1" });
  await app.register(userRoutes, { prefix: "/api/v1" });
  await app.register(storeRoutes, { prefix: "/api/v1" });
  await app.register(postRoutes, { prefix: "/api/v1" });
  await app.register(storyRoutes, { prefix: "/api/v1" });
  await app.register(mediaRoutes, { prefix: "/api/v1" });
  await app.register(chatRoutes, { prefix: "/api/v1" });
  await app.register(orderRoutes, { prefix: "/api/v1" });
  await app.register(notificationRoutes, { prefix: "/api/v1" });
  await app.register(quickReplyRoutes, { prefix: "/api/v1" });
  await app.register(notificationRequestRoutes, { prefix: "/api/v1" });
  await app.register(realtimeGateway, { prefix: "/api/v1" });

  return app;
}
