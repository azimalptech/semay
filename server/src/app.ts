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
import { busHealth, isBusRequired, isBusUnavailable } from "./realtime/bus.js";
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
import { shareRoutes } from "./share/routes.js";

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

  // Readiness — the DB check, kept separate from /health and registered AFTER
  // the rate limiter above, so the throttle actually covers it. Fastify
  // snapshots a route's hooks when the route is added, so while this sat above
  // the register() call it was as exempt as /health — measured: with
  // RATE_LIMIT_MAX_PER_MIN=5, /api/v1/stores began answering 429 on the sixth
  // request while /health/ready answered 200 twelve times running. The comment
  // here and docs/08 §"health endpoints" + docs/09's checklist all claimed it
  // was throttled; now it is. Result is cached briefly (db.ts) so a burst of
  // probes still collapses into one query.
  //
  // The realtime bus is REPORTED here and never decides the status code. A
  // REDIS_URL pointing at nothing used to leave this answering 200 {ok:true}
  // while every chat thread on every phone had silently stopped updating, so
  // `degraded` (the bus is not ready — events reach this process's sockets
  // only) and `realtime` (this process can deliver cross-process at all) are
  // both on the body. But this is the path an HTTP load balancer polls, and
  // failing it on the bus turned a realtime outage into a total one: every box
  // sharing one Redis crosses the grace period together, so the balancer ends
  // up with no healthy backend for login, feed, stores, orders and media —
  // none of which need Redis. The fail-closed verdict lives on
  // /health/realtime below instead.
  //
  // `lastError` / `lastErrorAt` from busHealth() are deliberately NOT in this
  // body: the endpoint needs no authentication, and those carry the internal
  // Redis host:port and the raw ioredis message ("publisher: connect
  // ECONNREFUSED 10.0.0.4:6379"). An operator reads them from the error line
  // bus.ts logs on every transition; the wire keeps the yes/no facts.
  app.get("/health/ready", async (_req, reply) => {
    const db = await isDbReady();
    const bus = busHealth();
    const degraded = bus.mode === "redis" && !bus.ready;
    return reply.code(db ? 200 : 503).send({
      ok: db,
      db,
      degraded,
      realtime: !isBusUnavailable(),
      bus: { mode: bus.mode, ready: bus.ready, droppedPublishes: bus.droppedPublishes },
    });
  });

  // Realtime readiness, on its own path — the fail-CLOSED half, for the
  // WebSocket upstream's health check and for alerting.
  //
  // This used to be folded into /health/ready, which made a Redis outage a
  // TOTAL outage: docs/09 §4 tells the operator to put several single-process
  // machines behind a load balancer sharing ONE Redis and set
  // REDIS_REQUIRED=true, and every box then crosses the 30 s grace at the same
  // instant. The balancer is left with zero healthy backends and login, feed,
  // stores, orders, media and chat REST all go dark — every one of which works
  // perfectly during a Redis outage. Only cross-process realtime fan-out does
  // not, and that is precisely what this path reports.
  //
  // The two signals that actually protect chat correctness are unchanged and
  // do not run through here: the gateway refuses a new subscribe and sweeps
  // the sockets it is already holding (gateway.ts, same isBusUnavailable()),
  // so a phone parked on a worker that cannot deliver is moved off it whatever
  // any balancer decides.
  app.get("/health/realtime", async (_req, reply) => {
    const bus = busHealth();
    const ok = !isBusUnavailable();
    return reply.code(ok ? 200 : 503).send({
      ok,
      // Same reason lastError/lastErrorAt are off /health/ready: no
      // authentication, so the Redis host:port and the raw ioredis message
      // stay in the log line (bus.ts) and out of the body.
      required: isBusRequired(),
      degraded: bus.mode === "redis" && !bus.ready,
      bus: { mode: bus.mode, ready: bus.ready, droppedPublishes: bus.droppedPublishes },
    });
  });

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

  // Public share pages, mounted at the ROOT (no prefix, no auth): a link
  // shared from the app is https://<origin>/p/<id> and has to work in any
  // browser, for someone who has never installed SeMay. Registered after the
  // rate limiter so its per-route cap composes with the global one, and
  // before the /api/v1 groups so the paths are unambiguous. See share/routes.ts.
  await app.register(shareRoutes);

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
