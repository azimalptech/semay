import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";

import { buildApp } from "../src/app.js";
import { generateDeviceToken, hashToken } from "../src/auth.js";
import { config } from "../src/config.js";
import { prisma } from "../src/db.js";
import { claimForDevice } from "../src/dispatch.js";

// The relay is the single point of failure between the API and every login in
// the system, and it had no automated tests at all — it was verified by hand
// once and nothing guarded it afterwards. These cover the invariants that are
// expensive to get wrong and easy to break in a refactor.
describe("SMS relay", () => {
  let app: FastifyInstance;
  const deviceIds: string[] = [];
  const messageIds: string[] = [];

  const basic = (user: string, pass: string) =>
    "Basic " + Buffer.from(`${user}:${pass}`).toString("base64");
  const API_AUTH = basic(config.API_USER, config.API_PASSWORD);

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.message.deleteMany({ where: { id: { in: messageIds } } });
    await prisma.device.deleteMany({ where: { id: { in: deviceIds } } });
    await prisma.$disconnect();
  });

  afterEach(async () => {
    // Each test starts from an empty queue, or leftovers from an earlier case
    // get claimed by the next one and the assertions drift.
    await prisma.message.deleteMany({ where: { id: { in: messageIds } } });
    messageIds.length = 0;
  });

  /** Registers a device with `slots` SIMs and returns it plus its plaintext token. */
  async function makeDevice(name: string, slots = 1) {
    const token = generateDeviceToken();
    const device = await prisma.device.create({
      data: {
        name,
        tokenHash: hashToken(token),
        simCards: {
          create: Array.from({ length: slots }, (_, i) => ({
            slotIndex: i,
            subscriptionId: 100 + i,
            carrierName: "TEST",
          })),
        },
      },
      include: { simCards: true },
    });
    deviceIds.push(device.id);
    return { device, token };
  }

  async function enqueue(phone: string, text = "SeMay code: 111111") {
    const res = await app.inject({
      method: "POST",
      url: "/3rdparty/v1/message",
      headers: { authorization: API_AUTH, "content-type": "application/json" },
      payload: { phoneNumbers: [phone], message: text },
    });
    expect(res.statusCode).toBe(202);
    const id = res.json().id as string;
    messageIds.push(id);
    return id;
  }

  describe("3rd-party API auth", () => {
    it("refuses with no credentials", async () => {
      const res = await app.inject({
        method: "POST",
        url: "/3rdparty/v1/message",
        payload: { phoneNumbers: ["+99319000001"], message: "x" },
      });
      expect(res.statusCode).toBe(401);
    });

    it("refuses a wrong password and a wrong user alike", async () => {
      for (const header of [
        basic(config.API_USER, "wrong"),
        basic("wrong", config.API_PASSWORD),
      ]) {
        const res = await app.inject({
          method: "POST",
          url: "/3rdparty/v1/message",
          headers: { authorization: header, "content-type": "application/json" },
          payload: { phoneNumbers: ["+99319000001"], message: "x" },
        });
        expect(res.statusCode).toBe(401);
      }
    });

    it("accepts valid credentials and returns the sms-gate.app shape", async () => {
      const res = await app.inject({
        method: "POST",
        url: "/3rdparty/v1/message",
        headers: { authorization: API_AUTH, "content-type": "application/json" },
        payload: { phoneNumbers: ["+99319000001"], message: "SeMay code: 424242" },
      });
      expect(res.statusCode).toBe(202);
      const body = res.json();
      messageIds.push(body.id);
      // server/src/auth/sms.ts depends on this shape; changing it silently
      // breaks OTP for the whole product.
      expect(body).toMatchObject({
        state: "Pending",
        isHashed: false,
        isEncrypted: false,
        recipients: [{ phoneNumber: "+99319000001", state: "Pending" }],
        textMessage: { text: "SeMay code: 424242" },
      });
      expect(body.states.Pending).toBeTruthy();
    });

    it("rejects a malformed body", async () => {
      const res = await app.inject({
        method: "POST",
        url: "/3rdparty/v1/message",
        headers: { authorization: API_AUTH, "content-type": "application/json" },
        payload: {},
      });
      expect(res.statusCode).toBe(400);
    });
  });

  describe("device auth", () => {
    it("refuses poll/hello/report without a valid token", async () => {
      for (const url of ["/device/poll", "/device/hello", "/device/report"]) {
        const res = await app.inject({
          method: "POST",
          url,
          headers: { authorization: "Bearer not-a-real-token", "content-type": "application/json" },
          payload: {},
        });
        expect(res.statusCode, `${url} must reject a bad token`).toBe(401);
      }
    });

    it("refuses a device that has been disabled", async () => {
      const { device, token } = await makeDevice("disabled-device");
      await prisma.device.update({ where: { id: device.id }, data: { enabled: false } });
      const res = await app.inject({
        method: "POST",
        url: "/device/poll",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      });
      expect(res.statusCode).toBe(401);
    });
  });

  describe("dispatch", () => {
    // THE core invariant, and the one most likely to be broken by a future
    // change: a message must be sent by exactly one SIM. Two devices claiming
    // the same message means a user receives the OTP twice and the store pays
    // for both.
    it("hands a message to exactly ONE device, never two", async () => {
      const a = await makeDevice("claim-race-a");
      const b = await makeDevice("claim-race-b");
      const id = await enqueue("+99319000010");

      // Both poll simultaneously — this is the race the in-process lock exists
      // to serialise.
      const [ja, jb] = await Promise.all([
        claimForDevice(a.device.id, 5),
        claimForDevice(b.device.id, 5),
      ]);

      const all = [...ja, ...jb].filter((j) => j.id === id);
      expect(all).toHaveLength(1);

      const msg = await prisma.message.findUniqueOrThrow({ where: { id } });
      expect(msg.state).toBe("Assigned");
      expect(msg.attempts).toBe(1);
    });

    it("only routes to SIMs belonging to the polling device", async () => {
      const mine = await makeDevice("owner", 2);
      const other = await makeDevice("other", 1);
      await enqueue("+99319000011");

      const jobs = await claimForDevice(mine.device.id, 5);
      expect(jobs).toHaveLength(1);
      const mineSubs = mine.device.simCards.map((s) => s.subscriptionId);
      expect(mineSubs).toContain(jobs[0]!.subscriptionId);

      // Nothing left for the other device.
      const none = await claimForDevice(other.device.id, 5);
      expect(none).toHaveLength(0);
    });

    it("respects the per-SIM minimum interval", async () => {
      const { device } = await makeDevice("paced", 1);
      await enqueue("+99319000012");
      await enqueue("+99319000013");

      // Claim one, so the SIM has a lastSentAt to be paced against. max=1
      // deliberately: with a zero gap a single call would drain both and there
      // would be nothing left to prove the gap is enforced.
      const first = await claimForDevice(device.id, 1);
      expect(first).toHaveLength(1);

      const originalGap = config.SIM_MIN_INTERVAL_MS;
      (config as { SIM_MIN_INTERVAL_MS: number }).SIM_MIN_INTERVAL_MS = 60_000;
      try {
        // The only SIM sent moments ago, so the second message must wait.
        const second = await claimForDevice(device.id, 5);
        expect(second).toHaveLength(0);
      } finally {
        (config as { SIM_MIN_INTERVAL_MS: number }).SIM_MIN_INTERVAL_MS = originalGap;
      }
    });

    it("refuses to exceed a SIM's hourly cap", async () => {
      const { device } = await makeDevice("capped", 1);
      const sim = await prisma.simCard.findFirstOrThrow({ where: { deviceId: device.id } });
      await prisma.simCard.update({
        where: { id: sim.id },
        data: { sentThisHour: config.SIM_MAX_PER_HOUR, hourStartedAt: new Date() },
      });
      await enqueue("+99319000014");

      const jobs = await claimForDevice(device.id, 5);
      expect(jobs).toHaveLength(0);
    });

    it("gives nothing to a device with no SIMs", async () => {
      const { device } = await makeDevice("no-sims", 0);
      await enqueue("+99319000015");
      expect(await claimForDevice(device.id, 5)).toHaveLength(0);
    });
  });

  describe("reporting and retry", () => {
    it("marks a message Sent, then Delivered", async () => {
      const { device, token } = await makeDevice("reporter");
      const id = await enqueue("+99319000016");
      await claimForDevice(device.id, 1);

      for (const state of ["Sent", "Delivered"] as const) {
        const res = await app.inject({
          method: "POST",
          url: "/device/report",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          payload: { type: "report", id, state },
        });
        expect(res.statusCode).toBe(200);
      }
      const msg = await prisma.message.findUniqueOrThrow({ where: { id } });
      expect(msg.state).toBe("Delivered");
      expect(msg.sentAt).not.toBeNull();
      expect(msg.deliveredAt).not.toBeNull();
    });

    // A dead SIM must not silently swallow every OTP routed to it.
    it("reassigns on failure, and fails terminally after MAX_ATTEMPTS", async () => {
      const { device, token } = await makeDevice("failer", 2);
      const id = await enqueue("+99319000017");

      for (let attempt = 1; attempt <= config.MAX_ATTEMPTS; attempt++) {
        const claimed = await claimForDevice(device.id, 1);
        expect(claimed, `attempt ${attempt} should be dispatched`).toHaveLength(1);
        const res = await app.inject({
          method: "POST",
          url: "/device/report",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          payload: { type: "report", id, state: "Failed", error: "simulated" },
        });
        expect(res.statusCode).toBe(200);
      }

      const msg = await prisma.message.findUniqueOrThrow({
        where: { id },
        include: { recipients: true },
      });
      expect(msg.state).toBe("Failed");
      expect(msg.attempts).toBe(config.MAX_ATTEMPTS);
      expect(msg.recipients[0]!.state).toBe("Failed");
    });

    // A report for someone else's message is either a bug or an attempt to
    // poison another device's queue.
    it("refuses a report for a message assigned to a different device", async () => {
      const owner = await makeDevice("owner-2");
      const stranger = await makeDevice("stranger");
      const id = await enqueue("+99319000018");
      await claimForDevice(owner.device.id, 1);

      const res = await app.inject({
        method: "POST",
        url: "/device/report",
        headers: {
          authorization: `Bearer ${stranger.token}`,
          "content-type": "application/json",
        },
        payload: { type: "report", id, state: "Sent" },
      });
      expect(res.statusCode).toBe(409);

      const msg = await prisma.message.findUniqueOrThrow({ where: { id } });
      expect(msg.state).toBe("Assigned");
    });
  });

  describe("HTTP fallback transport", () => {
    it("registers SIMs over /device/hello and then receives work by polling", async () => {
      const token = generateDeviceToken();
      const device = await prisma.device.create({
        data: { name: "polling-only", tokenHash: hashToken(token) },
      });
      deviceIds.push(device.id);

      const hello = await app.inject({
        method: "POST",
        url: "/device/hello",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        payload: {
          type: "hello",
          sims: [{ slotIndex: 0, subscriptionId: 77, carrierName: "TEST" }],
        },
      });
      expect(hello.statusCode).toBe(200);

      const id = await enqueue("+99319000019");
      const poll = await app.inject({
        method: "POST",
        url: "/device/poll",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      });
      expect(poll.statusCode).toBe(200);
      const jobs = poll.json().jobs as { id: string; subscriptionId: number }[];
      expect(jobs.map((j) => j.id)).toContain(id);
      expect(jobs.find((j) => j.id === id)!.subscriptionId).toBe(77);
    });

    it("disables SIMs the handset no longer reports", async () => {
      const { device, token } = await makeDevice("swapper", 2);
      const res = await app.inject({
        method: "POST",
        url: "/device/hello",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        payload: {
          type: "hello",
          sims: [{ slotIndex: 0, subscriptionId: 100, carrierName: "TEST" }],
        },
      });
      expect(res.statusCode).toBe(200);

      const sims = await prisma.simCard.findMany({
        where: { deviceId: device.id },
        orderBy: { slotIndex: "asc" },
      });
      expect(sims[0]!.enabled).toBe(true);
      // Slot 1 vanished from the report, so it must stop receiving work — but
      // still exist, so historical messages resolve which SIM sent them.
      expect(sims[1]!.enabled).toBe(false);
    });
  });

  describe("status endpoints", () => {
    it("reports a polling device as online with transport=polling", async () => {
      const { device } = await makeDevice("status-check");
      await prisma.device.update({
        where: { id: device.id },
        data: { lastSeenAt: new Date() },
      });

      const res = await app.inject({
        method: "GET",
        url: "/3rdparty/v1/device",
        headers: { authorization: API_AUTH },
      });
      expect(res.statusCode).toBe(200);
      const row = (res.json() as { id: string; online: boolean; transport: string }[]).find(
        (d) => d.id === device.id
      );
      // Reachable by polling counts as online; reporting it offline sends
      // whoever is triaging a missing OTP after the wrong thing entirely.
      expect(row?.online).toBe(true);
      expect(row?.transport).toBe("polling");
    });

    it("health does not depend on the database", async () => {
      const res = await app.inject({ method: "GET", url: "/health" });
      expect(res.statusCode).toBe(200);
      expect(res.json().ok).toBe(true);
    });
  });
});
