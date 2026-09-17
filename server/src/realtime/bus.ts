import cluster from "node:cluster";

import type { FastifyBaseLogger } from "fastify";
import { Redis, type RedisOptions } from "ioredis";

import { config } from "../config.js";
import { withTimeout } from "../lib/withTimeout.js";

export type RealtimeEvent =
  | { type: "snapshot"; data: unknown }
  | { type: "upsert"; data: unknown }
  | { type: "remove"; id: string }
  // Receipt roll-up on a `chat:{id}:messages` channel: every message sent by
  // `senderRole` with id <= `upToMessageId` that lacked the stamp now carries
  // `at`. Replaces re-sending the whole 200-message snapshot on each
  // delivered/read receipt — see chats/service.ts markReceipts for the cost that
  // motivated it. `upToMessageId` is the newest row the server actually stamped
  // (null when it stamped none): a message that reached the socket a moment
  // before the receipt was not in that set, and the client must not show it as
  // seen. `fromMessageId` is the exclusive lower bound — the reader's hide
  // cutoff (chats.hiddenBy*UpToId), null when they have none: rows at or below
  // it are invisible to the reader, were not stamped, and must not be shown
  // as seen either.
  | {
      type: "receipts";
      data: {
        senderRole: "user" | "admin";
        status: "delivered" | "read";
        at: string;
        upToMessageId: string | null;
        fromMessageId: string | null;
      };
    };

// Pub-sub seam for the WebSocket gateway. Two backends behind one interface:
//
//   REDIS_URL unset — a plain in-process EventEmitter. Correct and fastest for a
//     single API process, which is all a small deployment needs.
//   REDIS_URL set   — Redis pub/sub, so N API processes behind a load balancer
//     all see each other's events. This is what makes horizontal scaling
//     possible: without it, two users on different processes would never see
//     each other's messages, because a publish would only ever reach sockets
//     attached to the process that happened to handle the write.
//
// Subscriptions are reference-counted per channel and the Redis SUBSCRIBE is
// only issued for the first local listener (and UNSUBSCRIBE'd after the last),
// so Redis never pushes traffic this process has nobody to deliver to.
//
// A set-but-unreachable REDIS_URL used to be invisible: ioredis queued every
// PUBLISH in process memory, SUBSCRIBE never settled so the gateway never sent
// its snapshot, every error event was swallowed, and /health/ready only asked
// the DB. Sockets stayed open and answered pings, so the phone showed a thread
// that simply stopped updating until the app was reopened (the REST re-seed).
// Now: a publish ALWAYS fans out to this process's own listeners directly and
// uses Redis only to reach the other processes, so local delivery cannot be
// held hostage by a Redis connection in any state (down, reconnecting, or
// subscribed-but-unconfirmed). Whatever Redis does not carry is therefore
// correct for a single process and partial for a cluster — which is why
// cluster.ts refuses to fork without Redis, and why the gateway sweeps its own
// sockets (and /health/realtime turns 503) after 30 s of no bus where Redis is
// required. /health/ready deliberately stays 200: see isBusUnavailable. Every
// transition is logged, and busHealth() exposes the state to both endpoints.
const CHANNEL_PREFIX = "semay:rt:";

/** Marks a payload as published BY THIS PROCESS, so the echo that comes back
 * on our own subscriber connection can be dropped instead of delivered twice.
 *
 * The previous rule decided at publish time — "the echo will arrive, so skip
 * local delivery" — from `subscriberLive`, a flag this module only raises once
 * `resubscribeAll()` has completed a full SUBSCRIBE round trip. ioredis
 * restores its own confirmed subscriptions as part of its reconnect,
 * independently of that flag, so in the window between Redis feeding us again
 * and `resubscribeAll()` resolving, a publish took BOTH paths and every socket
 * on this process saw the same upsert twice. (The same window opens for a
 * SUBSCRIBE that timed out at 3 s and is confirmed late — see redisSubscribe.)
 * Nothing user-visible followed, because every client consumer is keyed by
 * message id, but a bus that can deliver an event twice is not a bus anyone
 * should have to reason around.
 *
 * Now the decision is made where the answer is actually known — on receipt —
 * and is right in every window: publish() always delivers locally (which is
 * also one Redis round trip faster), Redis carries the event to the OTHER
 * processes, and their subscribers see a tag that is not theirs. */
const ORIGIN_TAG = `${process.pid}:${Date.now().toString(36)}:${Math.random().toString(36).slice(2, 10)}`;
type Envelope = RealtimeEvent & { __o?: string };

// A Redis SUBSCRIBE that has not been confirmed in this long is treated as
// failed for now: the gateway must send its snapshot regardless, and the next
// 'ready' re-issues the subscribe. Short, because the snapshot waits on it.
const SUBSCRIBE_TIMEOUT_MS = 3_000;
// How long boot waits for Redis before declaring it unreachable. Long enough
// for a Redis service still starting after a reboot; a refused loopback
// connection is known within milliseconds either way.
const BOOT_PROBE_TIMEOUT_MS = 5_000;
// ioredis retries forever with growing delays; a dead Redis emits the same
// error on every attempt. Once per distinct message, then once a minute.
const ERROR_LOG_INTERVAL_MS = 60_000;
// How long a graceful QUIT may take before shutdown stops waiting on it.
const CLOSE_QUIT_TIMEOUT_MS = 1_000;

const listeners = new Map<string, Set<(event: RealtimeEvent) => void>>();
// Channels whose Redis SUBSCRIBE was rejected or timed out while the
// connection was otherwise usable — i.e. channels on which this process would
// MISS another process's events until the next 'ready' re-issues them
// (resubscribeAll). Local delivery never depends on it (publish() always fans
// out here first); it is the cross-process gap, reported as
// busHealth().pendingChannels.
const pendingRedis = new Set<string>();

let publisher: Redis | undefined;
let subscriber: Redis | undefined;
// True only once the subscriber connection is 'ready' AND every channel in
// `listeners` has been re-confirmed on it. ioredis emits 'ready' before it
// re-issues its own subscriptions after a reconnect, so a publish routed to
// Redis in that window would echo back to nobody.
let subscriberLive = false;
let notReadySince: number | undefined;
// Set by verifyBusAtBoot when it reported Redis unreachable, so a Redis that
// merely came up late still gets its recovery line (no error is recorded for
// a connection that was only slow).
let reportedUnreachable = false;
let closing = false;
let lastError: string | null = null;
let lastErrorAt: number | null = null;
// Publishes that did not reach Redis (delivered in-process only). In a single
// process nothing was lost; in a cluster every other worker missed them.
let droppedPublishes = 0;
let droppedSinceDown = 0;

/** ONE promise shared by every subscribe waiting on a connection attempt.
 *
 * awaitSubscriberUsable() used to attach its own `once(subscriber,'ready')` +
 * `once(subscriber,'close')` per call, and node's `events.once` attaches an
 * 'error' listener alongside each — ~6 listeners on the single module-level
 * client per in-flight subscribe. That branch is entered exactly when Redis is
 * SLOW rather than refused (a firewall DROP, a hung box keeps status
 * 'connecting' for the whole 5 s connectTimeout), which is the degradation
 * this module exists to survive: one socket subscribing 12 channels in a burst
 * against a blackholed Redis printed three MaxListenersExceededWarning lines
 * into the log an operator is trying to read, and EventEmitter add/remove is a
 * push + indexOf/splice, so N concurrent waiters cost O(N^2) on one emitter —
 * at the cluster scale in docs/08 §2 a Redis blackhole means thousands of
 * phones re-subscribing at once.
 *
 * Now the connection handlers installed at construction settle this one
 * promise for everybody: zero listeners are attached per subscribe, and N
 * waiters cost N promise resolutions. The timer is shared too, so a caller
 * that arrives late in a window waits out only its remainder — a shorter wait
 * than SUBSCRIBE_TIMEOUT_MS is always safe, because a channel that gives up is
 * marked pending and re-subscribed by resubscribeAll() on the next 'ready'. */
let usableWaiter: { promise: Promise<boolean>; settle: (usable: boolean) => void } | undefined;

function settleSubscriberWaiter(usable: boolean): void {
  const waiter = usableWaiter;
  if (!waiter) return;
  usableWaiter = undefined;
  waiter.settle(usable);
}

export type BusLogger = Pick<FastifyBaseLogger, "info" | "warn" | "error">;

// Same pattern as notifications/push.ts: the bus is created at import, before
// any logger exists, so index.ts/cluster.ts bind the process logger at boot.
// Silent until then — the test suite binds a spy to assert on the lines.
let log: BusLogger = { info() {}, warn() {}, error() {} };
// Per connection: the two clients fail in lockstep against a dead Redis, and a
// single "last message" would see them alternate and log every attempt.
const lastLoggedError = new Map<string, { message: string; at: number }>();
let suppressedErrors = 0;

export function bindBusLogger(logger: BusLogger): void {
  log = logger;
  // Errors recorded before binding went nowhere; let the first one through.
  lastLoggedError.clear();
}

/** host:port of REDIS_URL for log lines and errors — never the credentials. */
function redisTarget(): string {
  try {
    const url = new URL(config.REDIS_URL);
    return `${url.hostname}:${url.port || "6379"}`;
  } catch {
    return config.REDIS_URL;
  }
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function recordError(which: "publisher" | "subscriber", err: unknown): void {
  const message = `${which}: ${errorMessage(err)}`;
  lastError = message;
  lastErrorAt = Date.now();
  const previous = lastLoggedError.get(which);
  if (previous?.message === message && lastErrorAt - previous.at < ERROR_LOG_INTERVAL_MS) {
    suppressedErrors += 1;
    return;
  }
  log.error(
    { redis: redisTarget(), err: message, suppressed: suppressedErrors },
    "realtime: Redis error — delivering in-process only until it is back"
  );
  lastLoggedError.set(which, { message, at: lastErrorAt });
  suppressedErrors = 0;
}

// A function on purpose: `client.status` changes underneath an await, which
// TypeScript's narrowing of a plain property comparison does not allow for.
function isReady(client: Redis): boolean {
  return client.status === "ready";
}

function isRedisLive(): boolean {
  return publisher === undefined || (isReady(publisher) && subscriberLive);
}

function onNotReady(): void {
  // closeBus() drops both connections on purpose; that is not a lost bus.
  if (notReadySince !== undefined || closing) return;
  notReadySince = Date.now();
  droppedSinceDown = 0;
  log.warn(
    { redis: redisTarget(), channels: listeners.size },
    "realtime: Redis connection lost — delivering in-process only until it reconnects"
  );
}

function onMaybeReady(): void {
  if (!isRedisLive() || notReadySince === undefined) return;
  const downMs = Date.now() - notReadySince;
  notReadySince = undefined;
  // The very first 'ready' is boot, which verifyBusAtBoot reports itself.
  if (lastError === null && !reportedUnreachable) return;
  reportedUnreachable = false;
  log.warn(
    { redis: redisTarget(), downMs, channels: listeners.size, droppedPublishes: droppedSinceDown },
    "realtime: Redis reconnected — re-subscribed every channel; the publishes counted here " +
      "were delivered to this process only while it was down"
  );
}

/** Re-issues SUBSCRIBE for every channel with a local listener once the
 * subscriber connection comes (back) up. ioredis re-subscribes only channels it
 * had confirmed before the drop — one whose SUBSCRIBE was rejected while Redis
 * was down is otherwise never subscribed at all. Redis treats a duplicate
 * SUBSCRIBE as a no-op, so re-issuing all of them is safe. */
async function resubscribeAll(): Promise<void> {
  if (!subscriber) return;
  const channels = [...listeners.keys()];
  try {
    if (channels.length > 0) await subscriber.subscribe(...channels.map((c) => CHANNEL_PREFIX + c));
  } catch (err) {
    // Dropped again mid-way; the next 'ready' retries.
    recordError("subscriber", err);
    return;
  }
  // Only what this call confirmed: a channel subscribed (and marked pending)
  // while the batch was in flight is still pending.
  for (const channel of channels) pendingRedis.delete(channel);
  subscriberLive = true;
  onMaybeReady();
}

if (config.REDIS_URL) {
  const options: RedisOptions = {
    lazyConnect: false,
    // No offline queue: a command issued while disconnected rejects at once
    // instead of piling up in memory and bursting out (or never) later. The
    // fallbacks below deliver in-process instead.
    enableOfflineQueue: false,
    connectTimeout: 5_000,
    maxRetriesPerRequest: 1,
    retryStrategy: (times) => Math.min(30_000, 500 * 2 ** times),
  };
  publisher = new Redis(config.REDIS_URL, options);
  subscriber = new Redis(config.REDIS_URL, options);
  // Not ready until both connections confirm; a 'close' before then must not
  // log "connection lost" — boot reports its own verdict.
  notReadySince = Date.now();
  subscriber.on("message", (channel: string, payload: string) => {
    if (!channel.startsWith(CHANNEL_PREFIX)) return;
    let parsed: Envelope;
    try {
      parsed = JSON.parse(payload) as Envelope;
    } catch {
      return; // never let a malformed payload take the process down
    }
    // Our own publish, already delivered locally by publish() — see there.
    // A publisher that predates the tag carries none, and its events are then
    // treated as another process's, which is what they are.
    const { __o: origin, ...event } = parsed;
    if (origin === ORIGIN_TAG) return;
    deliverLocal(channel.slice(CHANNEL_PREFIX.length), event as RealtimeEvent);
  });
  for (const [name, client] of [
    ["publisher", publisher],
    ["subscriber", subscriber],
  ] as const) {
    client.on("error", (err: Error) => {
      recordError(name, err);
      // A refused/failed connection attempt is the fast path out of
      // awaitSubscriberUsable — same verdict `once()`'s implicit 'error'
      // listener used to produce, now from the one handler installed here.
      if (name === "subscriber") settleSubscriberWaiter(false);
    });
    client.on("close", () => {
      if (name === "subscriber") {
        subscriberLive = false;
        settleSubscriberWaiter(false);
      }
      onNotReady();
    });
  }
  publisher.on("ready", onMaybeReady);
  subscriber.on("ready", () => {
    settleSubscriberWaiter(true);
    void resubscribeAll();
  });
}

function deliverLocal(channel: string, event: RealtimeEvent): void {
  const set = listeners.get(channel);
  if (!set) return;
  // Copy before iterating: a listener may unsubscribe itself on delivery.
  for (const listener of [...set]) {
    try {
      listener(event);
    } catch {
      /* one bad socket must not stop the fan-out to the rest */
    }
  }
}

export function publish(channel: string, event: RealtimeEvent): void {
  // This process's own sockets are served directly, always and immediately —
  // the Redis echo is for the OTHER processes and is dropped here by ORIGIN_TAG
  // when it comes back. Local delivery therefore never depends on the state of
  // a Redis connection, which is the whole point of the fallback.
  deliverLocal(channel, event);
  if (!publisher) return;
  if (isReady(publisher)) {
    const envelope: Envelope = { ...event, __o: ORIGIN_TAG };
    publisher.publish(CHANNEL_PREFIX + channel, JSON.stringify(envelope)).catch((err: unknown) => {
      // Delivered here, but no other process saw it.
      recordError("publisher", err);
      droppedPublishes += 1;
      droppedSinceDown += 1;
    });
    return;
  }
  droppedPublishes += 1;
  droppedSinceDown += 1;
}

/** Waits for the subscriber connection to be usable, but only while an attempt
 * is actually in progress. Between attempts (ioredis backing off after a
 * refused connect) the answer is already known, and the gateway's snapshot
 * must not wait on a Redis that is down. */
async function awaitSubscriberUsable(): Promise<boolean> {
  if (!subscriber) return false;
  if (isReady(subscriber)) return true;
  if (subscriber.status !== "connecting" && subscriber.status !== "connect") return false;
  // No listener is attached to `subscriber` here, by anyone, ever — see
  // usableWaiter. The 'ready'/'close'/'error' handlers installed once at
  // construction settle this promise for every concurrent caller.
  if (!usableWaiter) {
    let resolve!: (usable: boolean) => void;
    const promise = new Promise<boolean>((r) => {
      resolve = r;
    });
    const timer = setTimeout(() => settleSubscriberWaiter(false), SUBSCRIBE_TIMEOUT_MS);
    // Never a reason to hold the process open.
    timer.unref();
    usableWaiter = {
      promise,
      settle: (usable) => {
        clearTimeout(timer);
        resolve(usable);
      },
    };
  }
  // `isReady` re-checked rather than trusted from the resolution: 'ready' can
  // be followed by a 'close' before this continuation runs.
  return (await usableWaiter.promise) && isReady(subscriber);
}

/** Issues the Redis SUBSCRIBE for a channel's first local listener. Never
 * throws and never waits longer than SUBSCRIBE_TIMEOUT_MS: on failure the
 * channel is marked pending — this process's own sockets are served either
 * way, but until the next 'ready' re-issues it, events published by ANOTHER
 * process on this channel are missed. The gateway's snapshot must not wait on
 * a Redis that is down, which is why this is bounded rather than awaited. */
async function redisSubscribe(channel: string): Promise<void> {
  if (!subscriber || !(await awaitSubscriberUsable())) {
    pendingRedis.add(channel);
    return;
  }
  const confirmed = subscriber.subscribe(CHANNEL_PREFIX + channel);
  try {
    await withTimeout(confirmed, SUBSCRIBE_TIMEOUT_MS, `redis SUBSCRIBE ${channel}`);
  } catch (err) {
    recordError("subscriber", err);
    pendingRedis.add(channel);
    // A late confirmation still counts: the channel IS subscribed on Redis
    // from that moment, so it stops being a gap in cross-process delivery.
    confirmed.then(
      () => pendingRedis.delete(channel),
      () => {}
    );
  }
}

/** Subscribes and resolves once the subscription is actually live.
 *
 * Awaiting matters with Redis: SUBSCRIBE is a round trip, and the gateway sends
 * its snapshot immediately after subscribing. Returning before the subscription
 * registered would open a window where an event published in between is lost —
 * the client would then sit on a stale snapshot with no diff to correct it. */
export async function subscribe(
  channel: string,
  listener: (event: RealtimeEvent) => void
): Promise<() => void> {
  let set = listeners.get(channel);
  const isFirst = set === undefined;
  if (!set) {
    set = new Set();
    listeners.set(channel, set);
  }
  set.add(listener);

  // Bounded: the local listener stays registered whatever Redis does, so
  // same-process events arrive either way and the caller's snapshot goes out.
  if (isFirst && subscriber) await redisSubscribe(channel);

  let released = false;
  return () => {
    if (released) return; // idempotent — double-unsubscribe must not over-decrement
    released = true;
    const current = listeners.get(channel);
    if (!current) return;
    current.delete(listener);
    if (current.size === 0) {
      listeners.delete(channel);
      pendingRedis.delete(channel);
      if (subscriber) void subscriber.unsubscribe(CHANNEL_PREFIX + channel).catch(() => {});
    }
  };
}

export interface BusHealth {
  /** "redis" whenever REDIS_URL is set — even while Redis is unreachable. */
  mode: "redis" | "local";
  /** Local mode is always ready. Redis mode: both connections confirmed live. */
  ready: boolean;
  /** Internal: carries the Redis host:port and the raw ioredis message, so it
   * is for the log line and the operator's own curl of the process, never for
   * the unauthenticated /health/ready or /health/realtime body (app.ts). */
  lastError: string | null;
  lastErrorAt: string | null;
  droppedPublishes: number;
  /** Channels with a local listener whose Redis SUBSCRIBE is not confirmed:
   * this process's own sockets are served, but another process's events on
   * them are missed until the next 'ready'. 0 in local mode. */
  pendingChannels: number;
}

/** What /health/ready and /health/realtime report (minus the error text — see
 * app.ts). A dead bus
 * used to be indistinguishable from a healthy one from outside the process;
 * these are the fields that tell. */
export function busHealth(): BusHealth {
  return {
    mode: publisher ? "redis" : "local",
    ready: isRedisLive(),
    lastError,
    lastErrorAt: lastErrorAt === null ? null : new Date(lastErrorAt).toISOString(),
    droppedPublishes,
    pendingChannels: pendingRedis.size,
  };
}

/** Diagnostic: how many EventEmitter listeners the shared subscriber
 * connection is holding, per event name. Flat regardless of how many
 * subscribes are in flight — that is the invariant usableWaiter exists to
 * keep, and what tests/realtime.bus-waiter.test.ts pins. Empty in local mode. */
export function subscriberListenerCounts(): Record<string, number> {
  if (!subscriber) return {};
  const counts: Record<string, number> = {};
  for (const event of subscriber.eventNames()) {
    counts[String(event)] = subscriber.listenerCount(event);
  }
  return counts;
}

/** How long the bus has been continuously not-ready; 0 when ready or local. */
export function busNotReadyForMs(): number {
  return notReadySince === undefined ? 0 : Date.now() - notReadySince;
}

/** Whether a missing bus is an outage rather than a degradation: a cluster
 * worker cannot serve correctly without cross-worker delivery, and an operator
 * running one process per machine opts in with REDIS_REQUIRED. */
export function isBusRequired(): boolean {
  return config.REDIS_REQUIRED || cluster.isWorker;
}

/** How long a required bus may be down before this process is treated as
 * unable to serve, rather than merely degraded. 30 s so a Redis restart is a
 * blip, not a flap: long enough to ride out a reconnect, short enough that a
 * load balancer stops routing here well inside a chat's patience. */
export const BUS_NOT_READY_GRACE_MS = 30_000;

/** This process cannot deliver correctly and has not been able to for the
 * grace period: the bus is required (cluster worker or REDIS_REQUIRED) and
 * Redis has been gone longer than BUS_NOT_READY_GRACE_MS.
 *
 * Three things key off it, and they have to agree. The gateway refuses a new
 * subscribe and sweeps the sockets it is ALREADY holding (gateway.ts) — that
 * is the half that actually protects chat, because taking a process out of
 * rotation does not close the WebSockets attached to it, and those are
 * precisely the phones with a thread open. GET /health/realtime answers 503,
 * for the WebSocket upstream's health check and for alerting (app.ts).
 *
 * What does NOT key off it is /health/ready, deliberately: that is the path an
 * HTTP balancer polls, and every box sharing one Redis crosses this grace
 * period at the same instant, so failing it would take login, feed, stores,
 * orders and media down over a dependency none of them use. */
export function isBusUnavailable(): boolean {
  return isBusRequired() && !isRedisLive() && busNotReadyForMs() > BUS_NOT_READY_GRACE_MS;
}

/** Boot-time verdict on the bus, logged through the bound logger. Resolves to
 * a message naming the Redis host:port when REDIS_URL is set but Redis did not
 * come up within the probe window, else null. The process boots either way —
 * cluster.ts's primary is the one place that makes it fatal (it refuses to
 * fork), because a cluster without Redis silently loses cross-worker events. */
export async function verifyBusAtBoot(): Promise<string | null> {
  if (!publisher) {
    log.info(
      { distributed: false },
      "realtime: in-process only — set REDIS_URL before running more than one process"
    );
    return null;
  }
  const deadline = Date.now() + BOOT_PROBE_TIMEOUT_MS;
  while (!isRedisLive() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  let problem: string | null = null;
  if (!isRedisLive()) {
    problem = lastError ?? `no connection within ${BOOT_PROBE_TIMEOUT_MS} ms`;
  } else {
    try {
      await withTimeout(publisher.ping(), 2_000, "redis PING");
    } catch (err) {
      problem = errorMessage(err);
    }
  }
  if (problem) {
    reportedUnreachable = true;
    log.error(
      { redis: redisTarget(), err: problem },
      "realtime: REDIS_URL is set but Redis is unreachable — falling back to in-process " +
        "delivery; multi-process deployments WILL lose cross-process events until it is back"
    );
    return `Redis at ${redisTarget()} is unreachable (${problem})`;
  }
  log.info(
    { distributed: true, redis: redisTarget() },
    "realtime: Redis pub-sub (safe for multiple processes)"
  );
  return null;
}

export async function closeBus(): Promise<void> {
  closing = true;
  // A subscribe still waiting on a connection attempt gets its answer now
  // rather than after its own timer — nothing is going to connect.
  settleSubscriberWaiter(false);
  // quit() needs a live connection to send QUIT; on a dead one it rejects at
  // once (no offline queue) and the client would keep reconnecting forever —
  // disconnect() stops that so the process can actually exit.
  //
  // Bounded, because "dead" is not the only bad state: a Redis that is
  // REACHABLE and hung (a firewall DROP, a swapping box) accepts the
  // connection and never answers, and an unbounded quit() then waits on it
  // forever — turning SIGTERM into a shutdown that only the service manager's
  // kill timeout ends. Nothing here is worth delaying an exit for: disconnect()
  // below is what actually stops the client.
  await withTimeout(
    Promise.allSettled([publisher?.quit(), subscriber?.quit()]),
    CLOSE_QUIT_TIMEOUT_MS,
    "redis QUIT"
  ).catch(() => {});
  publisher?.disconnect();
  subscriber?.disconnect();
}
