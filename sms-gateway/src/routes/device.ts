import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { WebSocket } from "ws";
import { z } from "zod";

import { hashToken } from "../auth.js";
import { config } from "../config.js";
import { prisma } from "../db.js";
import { applyReport, claimForDevice, dispatchPending, waitForWork } from "../dispatch.js";
import * as registry from "../registry.js";

/** How long /poll holds an idle request before answering "nothing".
 * Comfortably under the 60s nginx proxy_read_timeout default, so the fallback
 * transport is not itself killed by the proxy that motivated it. */
const POLL_HOLD_MS = 25_000;

const simSchema = z.object({
  slotIndex: z.number().int().min(0).max(7),
  subscriptionId: z.number().int(),
  carrierName: z.string().max(120).default(""),
  phoneNumber: z.string().max(20).default(""),
});

/** Sent by the handset immediately after the socket opens. The SIM list is
 * refreshed on every connect rather than only at registration: SIMs get
 * swapped, disabled, or run out of balance, and a stale list means dispatch
 * keeps routing to a slot that is no longer there. */
const helloSchema = z.object({
  type: z.literal("hello"),
  sims: z.array(simSchema).max(8),
});

const reportSchema = z.object({
  type: z.literal("report"),
  id: z.string().min(1),
  state: z.enum(["Sent", "Delivered", "Failed"]),
  error: z.string().max(500).optional(),
  recipients: z
    .array(
      z.object({
        phoneNumber: z.string(),
        state: z.enum(["Sent", "Delivered", "Failed"]),
        error: z.string().max(500).optional(),
      })
    )
    .optional(),
});

const clientMessage = z.union([helloSchema, reportSchema, z.object({ type: z.literal("pong") })]);

/** Resolves a bearer token to a device, or null. */
async function authenticate(token: string | undefined) {
  if (!token) return null;
  const device = await prisma.device.findUnique({ where: { tokenHash: hashToken(token) } });
  if (!device || !device.enabled) return null;
  return device;
}

/** Records the SIMs a handset reports. Shared by both transports so a device
 * that falls back to HTTP registers exactly the same way it would over the
 * socket. Anything the handset no longer lists is disabled rather than deleted,
 * so historical messages still resolve which SIM sent them. */
async function applyHello(
  deviceId: string,
  sims: { slotIndex: number; subscriptionId: number; carrierName: string; phoneNumber: string }[]
): Promise<void> {
  await prisma.$transaction([
    ...sims.map((s) =>
      prisma.simCard.upsert({
        where: { deviceId_slotIndex: { deviceId, slotIndex: s.slotIndex } },
        create: {
          deviceId,
          slotIndex: s.slotIndex,
          subscriptionId: s.subscriptionId,
          carrierName: s.carrierName,
          phoneNumber: s.phoneNumber,
        },
        update: {
          subscriptionId: s.subscriptionId,
          carrierName: s.carrierName,
          phoneNumber: s.phoneNumber,
          enabled: true,
        },
      })
    ),
    prisma.simCard.updateMany({
      where: { deviceId, slotIndex: { notIn: sims.map((s) => s.slotIndex) } },
      data: { enabled: false },
    }),
  ]);
}

async function handleFrame(deviceId: string, raw: string): Promise<void> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return;
  }
  const msg = clientMessage.safeParse(parsed);
  if (!msg.success) return;

  if (msg.data.type === "pong") {
    await prisma.device.update({ where: { id: deviceId }, data: { lastSeenAt: new Date() } });
    return;
  }

  if (msg.data.type === "hello") {
    await applyHello(deviceId, msg.data.sims);
    void dispatchPending();
    return;
  }

  await applyReport(msg.data.id, deviceId, msg.data.state, msg.data.error, msg.data.recipients);
  // A handset that just finished a message is immediately eligible for the
  // next one, subject to its SIM's pacing.
  void dispatchPending();
}

/** Bearer auth for the HTTP fallback endpoints. */
async function requireDevice(req: FastifyRequest, reply: FastifyReply) {
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : undefined;
  const device = await authenticate(token);
  if (!device) {
    await reply.code(401).send({ error: "UNAUTHORIZED" });
    return null;
  }
  return device;
}

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
  // Treat an empty JSON body as {}. /poll takes no input at all, so demanding
  // a body from it is a trap for any client that does not happen to send "{}"
  // — and because Fastify parses the body before preHandlers run, the failure
  // surfaces as a confusing 400 even when the real problem is a bad token.
  // Scoped to this plugin; the 3rd-party API still rejects malformed input.
  app.addContentTypeParser(
    "application/json",
    { parseAs: "string" },
    (_req, body, done) => {
      const raw = typeof body === "string" ? body.trim() : "";
      if (raw === "") return done(null, {});
      try {
        done(null, JSON.parse(raw));
      } catch (err) {
        done(err as Error);
      }
    }
  );

  // Liveness for the handset's own diagnostics screen — deliberately
  // unauthenticated and free of any device detail.
  app.get("/ping", async () => ({ ok: true }));

  // ── HTTP fallback transport ──────────────────────────────────────────────
  //
  // A WebSocket is the better path when it holds, but it does not always hold:
  // nginx idle timeouts, carrier NAT, Doze, and flaky upstream links all sever
  // it, sometimes without either end noticing. A gateway with exactly one
  // transport therefore has a single point of failure sitting between the
  // server and every login in the system.
  //
  // These endpoints are that second path. They are not a lesser mode — a
  // handset that can only ever poll works completely, just with slightly more
  // request overhead. Claiming is atomic and shared with the socket path
  // (dispatch.claimForDevice runs under the same lock as the push), so the two
  // transports can be live at once without a message ever going out twice.

  app.post("/hello", async (req, reply) => {
    const device = await requireDevice(req, reply);
    if (!device) return;
    const parsed = helloSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    await applyHello(device.id, parsed.data.sims);
    await prisma.device.update({ where: { id: device.id }, data: { lastSeenAt: new Date() } });
    return reply.send({ ok: true });
  });

  app.post("/poll", async (req, reply) => {
    const device = await requireDevice(req, reply);
    if (!device) return;

    await prisma.device.update({ where: { id: device.id }, data: { lastSeenAt: new Date() } });

    let jobs = await claimForDevice(device.id);
    if (jobs.length === 0) {
      // Hold the request open briefly rather than answering "nothing" straight
      // away: it turns polling from a latency floor into something close to
      // push, without the handset hammering us every second.
      await waitForWork(POLL_HOLD_MS);
      jobs = await claimForDevice(device.id);
    }
    return reply.send({ jobs });
  });

  app.post("/report", async (req, reply) => {
    const device = await requireDevice(req, reply);
    if (!device) return;
    const parsed = reportSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const applied = await applyReport(
      parsed.data.id,
      device.id,
      parsed.data.state,
      parsed.data.error,
      parsed.data.recipients
    );
    // 409, not 404: the message exists but is not this device's to report on.
    // Worth distinguishing, because in practice it means a handset resent a
    // report for work that was already reclaimed and given to another SIM.
    if (!applied) return reply.code(409).send({ error: "NOT_ASSIGNED_TO_THIS_DEVICE" });
    return reply.send({ ok: true });
  });

  if (!config.WEBSOCKET_ENABLED) {
    app.log.warn("WEBSOCKET_ENABLED=false — devices must use the HTTP polling transport");
    return;
  }

  app.get("/ws", { websocket: true }, (socket: WebSocket, req) => {
    // The message listener is attached SYNCHRONOUSLY, before any await.
    //
    // A handset sends `hello` the instant the socket opens. Authenticating
    // first means awaiting the database, and any frame arriving in that window
    // would land with no listener attached and be dropped — so the device would
    // come online with no SIMs registered and dispatch would never route to it.
    // The symptom is maddening to debug: the handset looks connected and
    // healthy, and not one message ever reaches it.
    //
    // Buffer frames until auth resolves, then replay them in arrival order.
    const buffered: string[] = [];
    let authenticated = false;
    let deviceId: string | null = null;

    // Frames are processed strictly one at a time: `hello` must be applied
    // before any report that followed it, or the SIM upsert races the dispatch
    // it triggers.
    let queue: Promise<void> = Promise.resolve();
    const enqueueFrame = (text: string): void => {
      queue = queue
        .then(async () => {
          if (!authenticated) {
            // Bounded, so an unauthenticated peer cannot grow this without
            // limit before its token has even been checked.
            if (buffered.length < 32) buffered.push(text);
            return;
          }
          if (deviceId) await handleFrame(deviceId, text);
        })
        .catch((err) => app.log.error({ err }, "device frame failed"));
    };

    socket.on("message", (raw) => enqueueFrame(raw.toString()));

    let heartbeat: NodeJS.Timeout | undefined;
    socket.on("close", () => {
      if (heartbeat) clearInterval(heartbeat);
      if (deviceId) registry.unbind(deviceId, socket);
    });
    socket.on("error", () => {
      if (heartbeat) clearInterval(heartbeat);
      if (deviceId) registry.unbind(deviceId, socket);
    });

    void (async () => {
      const header = req.headers.authorization ?? "";
      const token = header.startsWith("Bearer ") ? header.slice(7) : undefined;
      const device = await authenticate(token);
      if (!device) {
        // 4401: application-level "your token is bad, do not just retry". The
        // app treats this as fatal and stops reconnecting rather than hammering
        // us forever with a revoked credential.
        socket.close(4401, "unauthorized");
        return;
      }

      deviceId = device.id;
      registry.bind(device.id, socket);
      await prisma.device.update({
        where: { id: device.id },
        data: { lastSeenAt: new Date() },
      });

      // Application-level heartbeat. A TCP socket through a carrier NAT can
      // stay "open" long after the far end is gone; without this the registry
      // reports a dead handset as online and dispatch keeps handing it work
      // that only ASSIGN_TIMEOUT_SECONDS later gets reclaimed.
      heartbeat = setInterval(() => {
        try {
          socket.send(JSON.stringify({ type: "ping" }));
        } catch {
          socket.terminate();
        }
      }, 30_000);

      // Replay anything that arrived while we were authenticating, then let
      // new frames through.
      const replay = buffered.splice(0, buffered.length);
      authenticated = true;
      for (const text of replay) {
        await handleFrame(device.id, text);
      }

      // A handset coming online is the most likely moment for queued work to
      // become dispatchable.
      void dispatchPending();
    })();
  });
}
