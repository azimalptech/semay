import type { SimCard } from "@prisma/client";

import { config } from "./config.js";
import { prisma } from "./db.js";
import * as registry from "./registry.js";

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

/// Dispatch is serialised through this promise chain.
///
/// Two concurrent dispatches could otherwise read the same SIM as "free",
/// both assign to it, and fire two messages back to back — defeating the
/// pacing that keeps the SIM from being flagged as A2P traffic. An in-process
/// lock is sufficient precisely because the socket registry is in-process too
/// (see registry.ts); both move to Redis together or not at all.
let chain: Promise<unknown> = Promise.resolve();
function serialised<T>(fn: () => Promise<T>): Promise<T> {
  const run = chain.then(fn, fn);
  // Swallow rejection on the chain itself so one failed dispatch does not
  // poison every dispatch after it; the caller still sees the real error.
  chain = run.catch(() => undefined);
  return run;
}

/** Rolls the hour/day counters forward if their window has elapsed. Returns the
 * effective counts without writing — the write happens in the same transaction
 * that claims the SIM, so a SIM inspected but not chosen is left untouched. */
function effectiveCounts(sim: SimCard, now: Date) {
  const hourExpired = now.getTime() - sim.hourStartedAt.getTime() >= HOUR_MS;
  const dayExpired = now.getTime() - sim.dayStartedAt.getTime() >= DAY_MS;
  return {
    hourExpired,
    dayExpired,
    sentThisHour: hourExpired ? 0 : sim.sentThisHour,
    sentToday: dayExpired ? 0 : sim.sentToday,
  };
}

/** The least-recently-used online SIM that is under both caps and past its
 * minimum gap, or null when every SIM is busy, capped, or offline. */
async function pickSim(now: Date): Promise<{ sim: SimCard; hourExpired: boolean; dayExpired: boolean } | null> {
  const online = registry.onlineDeviceIds();
  if (online.length === 0) return null;

  const sims = await prisma.simCard.findMany({
    where: {
      enabled: true,
      deviceId: { in: online },
      device: { enabled: true },
    },
    // MySQL sorts NULLs first on ASC, so a SIM that has never sent is picked
    // ahead of one that has — which is what we want for spreading load across
    // newly added handsets.
    orderBy: { lastSentAt: "asc" },
  });

  for (const sim of sims) {
    const counts = effectiveCounts(sim, now);
    if (counts.sentThisHour >= config.SIM_MAX_PER_HOUR) continue;
    if (counts.sentToday >= config.SIM_MAX_PER_DAY) continue;
    if (
      sim.lastSentAt &&
      now.getTime() - sim.lastSentAt.getTime() < config.SIM_MIN_INTERVAL_MS
    ) {
      continue;
    }
    return { sim, hourExpired: counts.hourExpired, dayExpired: counts.dayExpired };
  }
  return null;
}

/** Assigns one Pending message to one SIM and pushes it to the handset.
 * Returns true if something was dispatched, so the caller can keep draining. */
async function dispatchOne(): Promise<boolean> {
  const now = new Date();

  const message = await prisma.message.findFirst({
    where: { state: "Pending" },
    orderBy: { pendingAt: "asc" },
    include: { recipients: true },
  });
  if (!message) return false;

  const picked = await pickSim(now);
  if (!picked) return false;
  const { sim, hourExpired, dayExpired } = picked;

  // Counters are incremented at ASSIGN time, not on send confirmation.
  // Reserving the slot up front is what actually enforces pacing: waiting for
  // the handset to confirm would let several messages be assigned to the same
  // SIM in the gap. The cost is that a failed send still consumes quota, which
  // errs toward sending less — the safe direction when the risk being managed
  // is the carrier blocking the SIM.
  await prisma.$transaction([
    prisma.message.update({
      where: { id: message.id },
      data: {
        state: "Assigned",
        assignedAt: now,
        deviceId: sim.deviceId,
        simCardId: sim.id,
        attempts: { increment: 1 },
      },
    }),
    prisma.simCard.update({
      where: { id: sim.id },
      data: {
        lastSentAt: now,
        sentThisHour: hourExpired ? 1 : { increment: 1 },
        sentToday: dayExpired ? 1 : { increment: 1 },
        ...(hourExpired ? { hourStartedAt: now } : {}),
        ...(dayExpired ? { dayStartedAt: now } : {}),
      },
    }),
  ]);

  const delivered = registry.send(sim.deviceId, {
    type: "send",
    id: message.id,
    subscriptionId: sim.subscriptionId,
    phoneNumbers: message.recipients.map((r) => r.phoneNumber),
    text: message.text,
  });

  if (!delivered) {
    // The socket died between picking it and writing to it. Put the message
    // back rather than leaving it Assigned to a handset that never saw it —
    // the sweep would eventually reclaim it, but that is ASSIGN_TIMEOUT_SECONDS
    // of dead air on a code that expires in five minutes.
    await prisma.message.update({
      where: { id: message.id },
      data: { state: "Pending", assignedAt: null, deviceId: null, simCardId: null },
    });
    return false;
  }

  return true;
}

/** Drains as many Pending messages as there is SIM capacity for. */
export function dispatchPending(): Promise<void> {
  return serialised(async () => {
    // Bounded so a large backlog cannot hold the lock indefinitely; the sweep
    // and the next enqueue both re-enter this.
    for (let i = 0; i < 50; i++) {
      if (!(await dispatchOne())) return;
    }
  });
}

/** Returns Assigned messages that a handset never reported on to the Pending
 * pool, or fails them once they have bounced MAX_ATTEMPTS times. */
export async function reclaimStalled(): Promise<void> {
  const cutoff = new Date(Date.now() - config.ASSIGN_TIMEOUT_SECONDS * 1000);

  const stalled = await prisma.message.findMany({
    where: { state: "Assigned", assignedAt: { lt: cutoff } },
    select: { id: true, attempts: true },
  });
  if (stalled.length === 0) return;

  const exhausted = stalled.filter((m) => m.attempts >= config.MAX_ATTEMPTS).map((m) => m.id);
  const retryable = stalled.filter((m) => m.attempts < config.MAX_ATTEMPTS).map((m) => m.id);

  const now = new Date();
  if (exhausted.length > 0) {
    await prisma.$transaction([
      prisma.message.updateMany({
        where: { id: { in: exhausted } },
        data: {
          state: "Failed",
          failedAt: now,
          lastError: `No delivery report after ${config.MAX_ATTEMPTS} attempts`,
        },
      }),
      prisma.recipient.updateMany({
        where: { messageId: { in: exhausted } },
        data: { state: "Failed", error: "No delivery report from any handset" },
      }),
    ]);
  }
  if (retryable.length > 0) {
    await prisma.message.updateMany({
      where: { id: { in: retryable } },
      data: { state: "Pending", assignedAt: null, deviceId: null, simCardId: null },
    });
  }
}

/** Creates a message and immediately tries to place it. */
export async function enqueue(text: string, phoneNumbers: string[]) {
  const message = await prisma.message.create({
    data: {
      text,
      recipients: { create: phoneNumbers.map((phoneNumber) => ({ phoneNumber })) },
    },
    include: { recipients: true },
  });

  // Not awaited: the API responds 202 as soon as the message is durable, the
  // same as the gateway contract we are replacing. Placing it is our problem,
  // not the caller's, and holding the login request open while a handset is
  // picked would add latency to every OTP.
  void dispatchPending();

  return message;
}

/** Applies a handset's report. `state` is the terminal state for the whole
 * message; per-recipient results are optional and only sent when they differ. */
export async function applyReport(
  messageId: string,
  deviceId: string,
  state: "Sent" | "Delivered" | "Failed",
  error?: string,
  recipients?: { phoneNumber: string; state: "Sent" | "Delivered" | "Failed"; error?: string }[]
): Promise<boolean> {
  const message = await prisma.message.findUnique({ where: { id: messageId } });
  // A report for someone else's message is either a bug or an attempt to
  // poison another device's queue; either way it is not applied.
  if (!message || message.deviceId !== deviceId) return false;

  const now = new Date();
  const stamp =
    state === "Sent"
      ? { sentAt: now }
      : state === "Delivered"
        ? { deliveredAt: now }
        : { failedAt: now };

  // A Failed report is not terminal while attempts remain — hand it to a
  // different SIM instead. A dead SIM (no balance, blocked) would otherwise
  // silently swallow every OTP routed to it.
  if (state === "Failed" && message.attempts < config.MAX_ATTEMPTS) {
    await prisma.message.update({
      where: { id: messageId },
      data: {
        state: "Pending",
        assignedAt: null,
        deviceId: null,
        simCardId: null,
        lastError: error ?? "Handset reported send failure",
      },
    });
    void dispatchPending();
    return true;
  }

  await prisma.message.update({
    where: { id: messageId },
    data: { state, ...stamp, ...(error ? { lastError: error } : {}) },
  });

  if (recipients && recipients.length > 0) {
    await Promise.all(
      recipients.map((r) =>
        prisma.recipient.updateMany({
          where: { messageId, phoneNumber: r.phoneNumber },
          data: { state: r.state, ...(r.error ? { error: r.error } : {}) },
        })
      )
    );
  } else {
    await prisma.recipient.updateMany({
      where: { messageId },
      data: { state, ...(error ? { error } : {}) },
    });
  }

  return true;
}
