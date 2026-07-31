import type { FastifyInstance } from "fastify";
import type { WebSocket } from "ws";

import { prisma } from "../db.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { findChannelHandler, type ChannelAuthCtx } from "./channels.js";
import { subscribe, type RealtimeEvent } from "./bus.js";

interface ClientMessage {
  type?: "subscribe" | "unsubscribe";
  channel?: string;
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

    socket.on("message", (raw: Buffer) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      if (!msg.channel || typeof msg.channel !== "string") return;
      const channel = msg.channel;

      if (msg.type === "subscribe") {
        if (unsubscribers.has(channel)) return; // already subscribed, no-op

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
        unsubscribers.set(channel, () => {});

        void (async () => {
          try {
            const ctx = await authContext();
            if (!ctx) {
              unsubscribers.delete(channel);
              return;
            }

            const allowed = await found.handler.authorize(ctx, found.match);
            if (!allowed) {
              unsubscribers.delete(channel);
              send(socket, { channel, type: "error", error: "FORBIDDEN" });
              return;
            }

            // Awaited so the subscription is live before the snapshot goes out —
            // otherwise an event landing in between is lost and the client keeps
            // a stale snapshot with no diff to correct it (see bus.ts).
            const unsub = await subscribe(channel, (event: RealtimeEvent) => {
              send(socket, { channel, ...event });
            });

            // The socket (or this channel) may have gone away mid-await.
            if (socket.readyState !== socket.OPEN || !unsubscribers.has(channel)) {
              unsub();
              return;
            }
            unsubscribers.set(channel, unsub);

            const data = await found.handler.snapshot(found.match);
            send(socket, { channel, type: "snapshot", data });
          } catch {
            unsubscribers.delete(channel);
          }
        })();
      } else if (msg.type === "unsubscribe") {
        unsubscribers.get(channel)?.();
        unsubscribers.delete(channel);
      }
    });

    socket.on("close", () => {
      claimsUnsub?.();
      for (const unsub of unsubscribers.values()) unsub();
      unsubscribers.clear();
    });
  });
}
