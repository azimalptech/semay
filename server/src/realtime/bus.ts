import { EventEmitter } from "node:events";

import { Redis } from "ioredis";

import { config } from "../config.js";

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
  // seen.
  | {
      type: "receipts";
      data: {
        senderRole: "user" | "admin";
        status: "delivered" | "read";
        at: string;
        upToMessageId: string | null;
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
const CHANNEL_PREFIX = "semay:rt:";

const localEmitter = new EventEmitter();
localEmitter.setMaxListeners(0); // one listener per subscribed socket

const listeners = new Map<string, Set<(event: RealtimeEvent) => void>>();

let publisher: Redis | undefined;
let subscriber: Redis | undefined;

if (config.REDIS_URL) {
  publisher = new Redis(config.REDIS_URL, { lazyConnect: false, maxRetriesPerRequest: null });
  subscriber = new Redis(config.REDIS_URL, { lazyConnect: false, maxRetriesPerRequest: null });
  subscriber.on("message", (channel: string, payload: string) => {
    if (!channel.startsWith(CHANNEL_PREFIX)) return;
    let event: RealtimeEvent;
    try {
      event = JSON.parse(payload) as RealtimeEvent;
    } catch {
      return; // never let a malformed payload take the process down
    }
    deliverLocal(channel.slice(CHANNEL_PREFIX.length), event);
  });
  // Redis pub/sub is fire-and-forget; a dropped connection must not be fatal —
  // ioredis reconnects and re-issues subscriptions on its own.
  for (const client of [publisher, subscriber]) {
    client.on("error", () => {
      /* transient; ioredis retries. Logged by the caller if it matters. */
    });
  }
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
  if (publisher) {
    // Only to Redis — the echo on our own subscriber connection is what performs
    // local delivery. Emitting locally here as well would double-deliver.
    void publisher.publish(CHANNEL_PREFIX + channel, JSON.stringify(event));
    return;
  }
  deliverLocal(channel, event);
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

  if (isFirst && subscriber) {
    try {
      await subscriber.subscribe(CHANNEL_PREFIX + channel);
    } catch {
      // Leave the local listener registered: same-process events still arrive,
      // and ioredis re-subscribes when the connection recovers.
    }
  }

  let released = false;
  return () => {
    if (released) return; // idempotent — double-unsubscribe must not over-decrement
    released = true;
    const current = listeners.get(channel);
    if (!current) return;
    current.delete(listener);
    if (current.size === 0) {
      listeners.delete(channel);
      if (subscriber) void subscriber.unsubscribe(CHANNEL_PREFIX + channel).catch(() => {});
    }
  };
}

/** True when events cross process boundaries. Logged at boot so a multi-process
 * deployment that forgot REDIS_URL is visible immediately rather than showing up
 * as "some users don't get realtime updates". */
export function isDistributed(): boolean {
  return publisher !== undefined;
}

export async function closeBus(): Promise<void> {
  await Promise.allSettled([publisher?.quit(), subscriber?.quit()]);
}
