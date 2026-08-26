import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";

import { secretEquals } from "../auth.js";
import { config } from "../config.js";
import { prisma } from "../db.js";
import { enqueue } from "../dispatch.js";
import * as registry from "../registry.js";

// The SeMay API's phone validation is stricter than ours deliberately: this
// relay is a dumb pipe and should not be the thing that decides a number is
// invalid. It only rejects what it cannot physically send.
const sendSchema = z.object({
  phoneNumbers: z.array(z.string().min(5).max(20)).min(1).max(50),
  message: z.string().min(1).max(1000),
});

/** HTTP Basic, matching sms-gate.app so `server/src/auth/sms.ts` needs no
 * change. Compared in constant time — a timing oracle on the API password
 * would be a slow but real path to sending SMS on someone else's SIMs. */
async function requireApiAuth(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  const header = req.headers.authorization ?? "";
  if (!header.startsWith("Basic ")) {
    await reply.code(401).header("WWW-Authenticate", "Basic").send({ error: "UNAUTHORIZED" });
    return;
  }
  const decoded = Buffer.from(header.slice(6), "base64").toString("utf8");
  const separator = decoded.indexOf(":");
  const user = separator === -1 ? decoded : decoded.slice(0, separator);
  const password = separator === -1 ? "" : decoded.slice(separator + 1);

  // Both compared, and both in constant time — checking the user first and
  // short-circuiting would leak whether a username is valid.
  const ok = secretEquals(user, config.API_USER) && secretEquals(password, config.API_PASSWORD);
  if (!ok) {
    await reply.code(401).header("WWW-Authenticate", "Basic").send({ error: "UNAUTHORIZED" });
  }
}

/** sms-gate.app returns state timestamps as a flat {state: iso} map. */
function statesOf(m: {
  pendingAt: Date;
  assignedAt: Date | null;
  sentAt: Date | null;
  deliveredAt: Date | null;
  failedAt: Date | null;
}): Record<string, string> {
  const out: Record<string, string> = { Pending: m.pendingAt.toISOString() };
  if (m.assignedAt) out.Assigned = m.assignedAt.toISOString();
  if (m.sentAt) out.Sent = m.sentAt.toISOString();
  if (m.deliveredAt) out.Delivered = m.deliveredAt.toISOString();
  if (m.failedAt) out.Failed = m.failedAt.toISOString();
  return out;
}

function messageResponse(m: {
  id: string;
  deviceId: string | null;
  state: string;
  text: string;
  pendingAt: Date;
  assignedAt: Date | null;
  sentAt: Date | null;
  deliveredAt: Date | null;
  failedAt: Date | null;
  recipients: { phoneNumber: string; state: string; error: string | null }[];
}) {
  return {
    id: m.id,
    deviceId: m.deviceId,
    state: m.state,
    // Present for shape-compatibility with sms-gate.app. We do not implement
    // hashing or end-to-end encryption of message bodies; the relay is on our
    // own server and the transport is TLS.
    isHashed: false,
    isEncrypted: false,
    recipients: m.recipients.map((r) => ({
      phoneNumber: r.phoneNumber,
      state: r.state,
      ...(r.error ? { error: r.error } : {}),
    })),
    states: statesOf(m),
    textMessage: { text: m.text },
  };
}

export async function thirdPartyRoutes(app: FastifyInstance): Promise<void> {
  app.addHook("preHandler", requireApiAuth);

  app.post("/message", async (req, reply) => {
    const body = sendSchema.safeParse(req.body);
    if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

    const message = await enqueue(body.data.message, body.data.phoneNumbers);

    // 202, not 200: the message is durable but not yet handed to a radio.
    // Matches the gateway contract the app server already expects.
    return reply.code(202).send(messageResponse({ ...message, text: message.text }));
  });

  app.get("/message/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const message = await prisma.message.findUnique({
      where: { id },
      include: { recipients: true },
    });
    if (!message) return reply.code(404).send({ error: "NOT_FOUND" });
    return reply.send(messageResponse(message));
  });

  app.get("/device", async (_req, reply) => {
    const devices = await prisma.device.findMany({
      include: { simCards: { where: { enabled: true } } },
      orderBy: { createdAt: "asc" },
    });

    return reply.send(
      devices.map((d) => ({
        id: d.id,
        name: d.name,
        createdAt: d.createdAt.toISOString(),
        lastSeen: d.lastSeenAt?.toISOString() ?? null,
        // Not part of the sms-gate.app shape, but the single most useful field
        // when triaging "why did no OTP arrive" — a device row can look healthy
        // while its socket has been gone for an hour.
        online: registry.isOnline(d.id),
        enabled: d.enabled,
        simCards: d.simCards.map((s) => ({
          slotIndex: s.slotIndex,
          simNumber: s.slotIndex + 1,
          carrierName: s.carrierName,
          sentThisHour: s.sentThisHour,
          sentToday: s.sentToday,
        })),
      }))
    );
  });
}
