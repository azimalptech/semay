import type { FastifyInstance } from "fastify";
import type { WebSocket } from "ws";

import { prisma } from "../db.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { withTimeout } from "../lib/withTimeout.js";
import { findChannelHandler, type ChannelAuthCtx } from "./channels.js";
import { isBusUnavailable, subscribe, type RealtimeEvent } from "./bus.js";

interface ClientMessage {
  type?: "subscribe" | "unsubscribe" | "ping";
  channel?: string;
}

// Server-side liveness probe interval. A phone that loses its network (carrier
// NAT reset, Doze, Wi-Fi→LTE handover, a tunnel dropping) does not close the
// TCP connection — the socket simply stops answering. Without a probe the
// server keeps the listener registered and serializes every event into a dead
// pipe until the OS gives up on the TCP connection, which can take many
// minutes. ws answers the CLIENT's protocol pings by itself; this is the
// server's own probe in the other direction. A peer that misses a whole
// interval is terminate()d, not close()d — a dead peer would never complete the
// closing handshake, and close() would wait for it.
const HEARTBEAT_INTERVAL_MS = 30_000;

// Upper bound on authorize → bus subscribe → snapshot. Whatever hangs inside
// it (a DB query, a Redis round trip), the client gets an answer: an
// unanswered subscribe used to leave the thread frozen with the socket
// looking perfectly healthy. Generous — the bus already bounds its own
// SUBSCRIBE at 3 s and a snapshot is a handful of indexed queries.
const SUBSCRIBE_DEADLINE_MS = 10_000;

// How often this process asks whether it can still deliver at all. Only the
// answer's transition matters, and the state it reads changes on a 30 s grace,
// so this is coarse on purpose — it costs one comparison per tick, and nothing
// per socket until it fires.
const BUS_SWEEP_INTERVAL_MS = 5_000;

// Hard ceiling on the channels ONE socket may hold at a time.
//
// Every channel costs a bus listener, an entry in this socket's map, and — on
// the way in — an authorize plus a snapshot (a chat thread's snapshot is 200
// rows). Nothing bounded that: an authenticated client could subscribe to
// unboundedly many, and the `store:{id}` handler added in this pass widened
// the reachable set again (it authorizes every authenticated user, like
// `post:{id}`, so one account can walk the whole store table). A real app is
// nowhere near this: the client refcounts and unsubscribes when the last
// listener goes (realtime_client.dart) and every consumer is autoDispose, so
// a socket holds the chat list, the open threads, and the posts/stores
// actually on screen — tens, not hundreds.
//
// Exported for tests/realtime.gateway.test.ts, which drives the bound over a
// real socket rather than restating the number.
export const MAX_CHANNELS_PER_SOCKET = 256;

// Token bucket per socket, in FRAMES. ws already caps each frame at 4 KiB
// (app.ts), which bounds the bytes but not the rate, and every subscribe frame
// costs DB work. A fast feed scroll is the legitimate worst case — one
// subscribe + one unsubscribe per post card entering and leaving the viewport
// — so the sustained rate is set well above that and the burst above an app
// launch's whole opening salvo.
export const FRAME_BUCKET_CAPACITY = 120;
export const FRAME_REFILL_PER_SEC = 30;

/** Close code for a client that outran the frame budget. Application range,
 * like BUS_UNAVAILABLE_CLOSE; the client reconnects through its backoff. */
export const FRAME_FLOOD_CLOSE = 4429;

/** Close code for "this process cannot deliver; reconnect somewhere else".
 * Application range (4000-4999) so it can never be confused with a protocol
 * close. The client treats it as an ordinary drop: reconnect through the
 * backoff, showing "Connecting…" meanwhile (realtime_client.dart). */
const BUS_UNAVAILABLE_CLOSE = 4503;

// Every socket this process is holding, and one timer for all of them.
//
// A worker whose required bus is gone can still ACCEPT sockets, answer their
// pings and serve its own snapshots — which is exactly the failure the client
// cannot detect: its silence rule only measures silence while a subscribe is
// outstanding (realtime_client.dart), so a phone whose snapshots already
// landed sits on `connected` with a frozen thread forever while another
// worker's publishes never reach it. Readiness turning 503 takes this worker
// out of rotation for NEW connections, but a load balancer does not close the
// WebSockets already attached to it. So the worker closes them itself: the
// client reconnects, lands somewhere that works, and says "Connecting…" until
// it does.
const liveSockets = new Set<WebSocket>();
let busSweep: NodeJS.Timeout | undefined;

function stopBusSweep(): void {
  if (!busSweep) return;
  clearInterval(busSweep);
  busSweep = undefined;
}

function startBusSweep(log: FastifyInstance["log"]): void {
  if (busSweep) return;
  busSweep = setInterval(() => {
    if (liveSockets.size === 0) {
      stopBusSweep();
      return;
    }
    if (!isBusUnavailable()) return;
    log.error(
      { sockets: liveSockets.size },
      "realtime: the bus this process needs has been down past the grace period — " +
        "closing its sockets so clients reconnect to a worker that can deliver"
    );
    for (const socket of [...liveSockets]) {
      socket.close(BUS_UNAVAILABLE_CLOSE, "BUS_UNAVAILABLE");
    }
  }, BUS_SWEEP_INTERVAL_MS);
  // Never a reason to keep the process alive.
  busSweep.unref();
}

function send(socket: WebSocket, payload: unknown): void {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

export async function realtimeGateway(app: FastifyInstance): Promise<void> {
  app.get("/ws", { websocket: true }, (socket: WebSocket, req) => {
    const token = (req.query as { token?: string } | undefined)?.token;
    if (!token) {
      socket.close(4401, "UNAUTHENTICATED");
      return;
    }

    let userId: string;
    try {
      userId = verifyAccessToken(token).sub;
    } catch {
      socket.close(4401, "UNAUTHENTICATED");
      return;
    }

    const unsubscribers = new Map<string, () => void>();
    liveSockets.add(socket);
    // app.log, not req.log: the sweep outlives this request, and a
    // request-scoped child logger would be held for the process's lifetime.
    startBusSweep(app.log);

    // Claims invalidation is event-driven, not polled. The previous version ran
    // one DB query per connection every 30s; at 20k concurrent sockets that is
    // ~660 queries/sec of pure overhead, scaling linearly with connection count
    // and doing nothing almost every time. bumpClaimsVersion now publishes on
    // this channel instead, so a demotion closes the socket in milliseconds
    // rather than up to 30s later, at zero steady-state cost.
    let claimsUnsub: (() => void) | undefined;
    void subscribe(`user:${userId}:claims`, () => {
      socket.close(4401, "CLAIMS_STALE");
    }).then((unsub) => {
      claimsUnsub = unsub;
      // The socket may already have closed while the subscribe was in flight.
      if (socket.readyState !== socket.OPEN) unsub();
    });

    // Authorization still re-reads role/storeIds from the DB rather than trusting
    // the token's snapshot — a demoted admin must not be able to subscribe to a
    // store's chats mid-session. But an app launch subscribes to many channels at
    // once (chat list, each open thread, visible posts), and doing two queries per
    // channel turned one launch into ~20 queries. Cached for a few seconds so a
    // burst collapses into a single lookup, which is still far fresher than the
    // 15-minute access token it replaces.
    const AUTH_CTX_TTL_MS = 5_000;
    let cachedCtx: { at: number; ctx: ChannelAuthCtx } | undefined;
    let ctxInFlight: Promise<ChannelAuthCtx | undefined> | undefined;

    async function authContext(): Promise<ChannelAuthCtx | undefined> {
      const now = Date.now();
      if (cachedCtx && now - cachedCtx.at < AUTH_CTX_TTL_MS) return cachedCtx.ctx;
      ctxInFlight ??= (async () => {
        try {
          const [user, storeAdminRows] = await Promise.all([
            prisma.user.findUnique({
              where: { id: userId },
              select: { role: true, deletedAt: true },
            }),
            prisma.storeAdmin.findMany({ where: { userId }, select: { storeId: true } }),
          ]);
          if (!user || user.deletedAt) return undefined;
          const ctx: ChannelAuthCtx = {
            userId,
            role: user.role,
            storeIds: storeAdminRows.map((r) => r.storeId),
          };
          cachedCtx = { at: Date.now(), ctx };
          return ctx;
        } finally {
          ctxInFlight = undefined;
        }
      })();
      return ctxInFlight;
    }

    let alive = true;
    socket.on("pong", () => {
      alive = true;
    });
    const heartbeat = setInterval(() => {
      if (socket.readyState !== socket.OPEN) return;
      if (!alive) {
        socket.terminate();
        return;
      }
      alive = false;
      socket.ping();
    }, HEARTBEAT_INTERVAL_MS);

    // Token bucket, refilled lazily from the clock — no timer per socket.
    let frameTokens = FRAME_BUCKET_CAPACITY;
    let lastRefill = Date.now();
    function spendFrameToken(): boolean {
      const now = Date.now();
      frameTokens = Math.min(
        FRAME_BUCKET_CAPACITY,
        frameTokens + ((now - lastRefill) / 1_000) * FRAME_REFILL_PER_SEC
      );
      lastRefill = now;
      if (frameTokens < 1) return false;
      frameTokens -= 1;
      return true;
    }

    const handleFrame = (raw: Buffer): void => {
      alive = true; // any traffic from the peer proves it is there
      // Counted before it is even parsed: the parse itself is the cost being
      // bounded here, and it runs synchronously inside ws's receiver.
      if (!spendFrameToken()) {
        req.log.warn({ userId }, "ws: frame flood — closing socket");
        socket.close(FRAME_FLOOD_CLOSE, "TOO_MANY_FRAMES");
        return;
      }
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      // JSON.parse happily returns null / a number / an array — the frame
      // `null` parsed fine and the property access below then threw a
      // TypeError synchronously inside ws's receiver, which nothing caught:
      // any authenticated client could take the whole process down with four
      // bytes. Only an object is a frame we know how to read.
      if (msg === null || typeof msg !== "object" || Array.isArray(msg)) return;
      // Application-level ping: the app sends this on resume-from-background to
      // learn within a couple of seconds whether the socket it kept survived
      // the suspension, instead of waiting for the next protocol ping cycle.
      if (msg.type === "ping") {
        send(socket, { type: "pong" });
        return;
      }
      if (!msg.channel || typeof msg.channel !== "string") return;
      const channel = msg.channel;

      if (msg.type === "subscribe") {
        if (unsubscribers.has(channel)) return; // already subscribed, no-op

        // Bounded, and told so rather than silently dropped: a client at the
        // ceiling has a bug (or is not a client), and CHANNEL_LIMIT is a
        // channel-level error the app handles exactly like FORBIDDEN — it does
        // not tear the socket down over one channel.
        if (unsubscribers.size >= MAX_CHANNELS_PER_SOCKET) {
          req.log.warn(
            { userId, channels: unsubscribers.size, channel },
            "ws: per-socket channel ceiling reached"
          );
          send(socket, { channel, type: "error", error: "CHANNEL_LIMIT" });
          return;
        }

        // This process cannot deliver another worker's events and has not been
        // able to for the grace period. Serving a snapshot here would hand the
        // phone a thread that looks live and then never moves — the exact
        // reported defect. SUBSCRIBE_FAILED is the server's own "not me": the
        // client retries the channel once and then stalls the socket, which
        // shows "Connecting…" and reconnects through the backoff until it
        // reaches a worker that works (realtime_client.dart).
        if (isBusUnavailable()) {
          send(socket, { channel, type: "error", error: "SUBSCRIBE_FAILED" });
          return;
        }

        const found = findChannelHandler(channel);
        if (!found) {
          send(socket, { channel, type: "error", error: "UNKNOWN_CHANNEL" });
          return;
        }

        // Mark the channel as claimed synchronously, before the awaits below.
        // A client that sends two subscribe frames for the same channel back to
        // back would otherwise pass the has() check twice and register two
        // listeners, of which only the last unsubscriber is retained — leaking a
        // listener (and a duplicate event stream) for the connection's lifetime.
        //
        // The placeholder is a unique function, and every step below checks the
        // map still holds THIS placeholder rather than merely "some entry": a
        // subscribe → unsubscribe → subscribe burst for one channel while the
        // first subscribe is still awaiting would otherwise see the second
        // attempt's placeholder, install a second bus listener over it, and
        // lose the first unsubscriber — double delivery for the socket's
        // lifetime and an orphaned listener after it.
        const placeholder = (): void => {};
        unsubscribers.set(channel, placeholder);
        const stillMine = (): boolean => unsubscribers.get(channel) === placeholder;
        // Set once the bus listener is installed over the placeholder, so the
        // failure path can release exactly what this attempt registered.
        let installed: (() => void) | undefined;
        const mine = (): boolean => unsubscribers.get(channel) === (installed ?? placeholder);

        void (async () => {
          try {
            await withTimeout(
              (async () => {
                const ctx = await authContext();
                if (!ctx) {
                  // The account is gone or soft-deleted while its 15-minute
                  // access token is still inside its TTL. This used to return
                  // in silence, which the client's snapshot deadline now reads
                  // as "the server is not delivering": it would drop the
                  // socket, reconnect (the token still verifies), subscribe,
                  // get silence again — forever, with "Connecting…" pinned on
                  // screen. FORBIDDEN rather than SUBSCRIBE_FAILED, because a
                  // missing user is final: the client hands it to the consumer
                  // instead of retrying.
                  if (stillMine()) unsubscribers.delete(channel);
                  send(socket, { channel, type: "error", error: "FORBIDDEN" });
                  return;
                }

                const allowed = await found.handler.authorize(ctx, found.match);
                if (!allowed) {
                  if (stillMine()) unsubscribers.delete(channel);
                  send(socket, { channel, type: "error", error: "FORBIDDEN" });
                  return;
                }

                // Awaited so the subscription is live before the snapshot goes
                // out — otherwise an event landing in between is lost and the
                // client keeps a stale snapshot with no diff to correct it
                // (see bus.ts).
                const unsub = await subscribe(channel, (event: RealtimeEvent) => {
                  send(socket, { channel, ...event });
                });

                // The socket (or this channel, or this attempt) may have gone
                // away mid-await.
                if (socket.readyState !== socket.OPEN || !stillMine()) {
                  unsub();
                  return;
                }
                installed = unsub;
                unsubscribers.set(channel, unsub);

                const data = await found.handler.snapshot(found.match, ctx);
                // The deadline may have passed mid-query: the client already
                // got its error frame and this attempt's listener is released.
                if (!mine()) return;
                send(socket, { channel, type: "snapshot", data });
              })(),
              SUBSCRIBE_DEADLINE_MS,
              `subscribe ${channel}`
            );
          } catch (err) {
            // Used to be silent: the placeholder vanished and the client sat on
            // a subscribe with no snapshot and no error, forever. Now it is
            // told, so it can retry (and show that it is reconnecting).
            //
            // The frame goes out ONLY while this attempt still owns the
            // channel. A subscribe → unsubscribe → subscribe burst on one
            // socket (leaving and re-entering a thread, a Riverpod consumer
            // rebuilding) can leave attempt A hanging while attempt B has
            // already installed its listener and delivered its snapshot; A
            // then hitting SUBSCRIBE_DEADLINE_MS used to tell the client the
            // channel had failed while it was working. The client treats
            // SUBSCRIBE_FAILED as a channel-level retry and, after a second
            // one, as a reason to drop the whole socket — so a superseded
            // attempt cost every channel on that connection a reconnect and a
            // REST re-seed. The log line stays unconditional: a superseded
            // attempt that blew up is still worth recording.
            const stale = !mine();
            if (!stale) {
              installed?.();
              unsubscribers.delete(channel);
              send(socket, { channel, type: "error", error: "SUBSCRIBE_FAILED" });
            }
            req.log.warn({ err, channel, stale }, "ws: subscribe failed");
          }
        })();
      } else if (msg.type === "unsubscribe") {
        unsubscribers.get(channel)?.();
        unsubscribers.delete(channel);
      }
    };

    // Belt and braces for the guard above: frames are attacker-controlled
    // input, and ws delivers them synchronously — an exception escaping here
    // is an uncaught exception for the whole process, not a failed request.
    socket.on("message", (raw: Buffer) => {
      try {
        handleFrame(raw);
      } catch (err) {
        req.log.warn({ err }, "ws: frame handler threw; closing socket");
        socket.close(1003, "BAD_FRAME");
      }
    });

    socket.on("close", () => {
      clearInterval(heartbeat);
      claimsUnsub?.();
      for (const unsub of unsubscribers.values()) unsub();
      unsubscribers.clear();
      liveSockets.delete(socket);
      if (liveSockets.size === 0) stopBusSweep();
    });
  });
}
