import type { FastifyInstance } from "fastify";
import type { WebSocket } from "ws";

import { prisma } from "../db.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { findChannelHandler } from "./channels.js";
import { subscribe, type RealtimeEvent } from "./bus.js";

// How often an open connection's cached claims_version is re-checked against
// the DB — a demoted/revoked user's socket gets force-closed instead of
// riding out the connection indefinitely (mirrors requireFreshAuth's HTTP
// check, but sockets have no natural "next request" to piggyback on).
const CLAIMS_RECHECK_MS = 30_000;

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
    let claimsVersion: number;
    try {
      const payload = verifyAccessToken(token);
      userId = payload.sub;
      claimsVersion = payload.claimsVersion;
    } catch {
      socket.close(4401, "UNAUTHENTICATED");
      return;
    }

    const unsubscribers = new Map<string, () => void>();

    const recheck = setInterval(() => {
      prisma.user
        .findUnique({ where: { id: userId }, select: { claimsVersion: true } })
        .then((u) => {
          if (!u || u.claimsVersion !== claimsVersion) {
            socket.close(4401, "CLAIMS_STALE");
          }
        })
        .catch(() => {
          /* transient DB hiccup — re-checked on the next tick */
        });
    }, CLAIMS_RECHECK_MS);

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

        // Re-fetch role/storeIds from the DB per subscribe rather than trusting
        // the connection's cached claimsVersion snapshot — cheap, and this is
        // exactly the kind of check that must not be allowed to go stale for
        // an entire connection's lifetime (a demoted admin subscribing to a
        // store's chats mid-session, say).
        prisma.user
          .findUnique({ where: { id: userId }, select: { role: true } })
          .then(async (u) => {
            if (!u) return;
            const storeAdminRows = await prisma.storeAdmin.findMany({
              where: { userId },
              select: { storeId: true },
            });
            const ctx = { userId, role: u.role, storeIds: storeAdminRows.map((r) => r.storeId) };

            const allowed = await found.handler.authorize(ctx, found.match);
            if (!allowed) {
              send(socket, { channel, type: "error", error: "FORBIDDEN" });
              return;
            }

            const unsub = subscribe(channel, (event: RealtimeEvent) => {
              send(socket, { channel, ...event });
            });
            unsubscribers.set(channel, unsub);

            const data = await found.handler.snapshot(found.match);
            send(socket, { channel, type: "snapshot", data });
          })
          .catch(() => {});
      } else if (msg.type === "unsubscribe") {
        unsubscribers.get(channel)?.();
        unsubscribers.delete(channel);
      }
    });

    socket.on("close", () => {
      clearInterval(recheck);
      for (const unsub of unsubscribers.values()) unsub();
      unsubscribers.clear();
    });
  });
}
