import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { config } from "../src/config.js";
import { prisma } from "../src/db.js";
import { type App } from "./helpers.js";

// The demo account: ONE phone number that logs in with a fixed code instead of
// a real SMS, because app-store reviewers cannot receive an SMS on a Turkmen
// number and a reviewer who cannot log in rejects the build.
//
// It is an authentication bypass whose credential is permanent and published —
// it sits in a review form and in this repo's docs — so the tests that matter
// most are the ones asserting how NARROW it is. Above all the privilege guard:
// promoting that number in the admin panel would otherwise hand the published
// code real privileges, and the only outward symptom would be a demo login
// that quietly did more than it should.
//
//   npm run test:demo-account
//
// Runs against a SYNTHETIC number supplied by that script, never the real
// configured one. An earlier version of this file read OTP_TEST_PHONE from the
// environment and deleted it between cases; pointed at a deployment's actual
// demo account that destroys live data, and it failed here on a foreign key
// from a store whose createdById referenced exactly that account. Tests clean
// up only rows they created themselves.
const TEST_PHONE = config.OTP_TEST_PHONE;
const TEST_CODE = config.OTP_TEST_CODE;
const enabled = TEST_PHONE !== "" && TEST_CODE !== "";

describe("OTP demo account (OTP_TEST_PHONE)", () => {
  let app: App;
  const createdIds: string[] = [];

  beforeAll(async () => {
    if (enabled) {
      const preexisting = await prisma.user.findUnique({ where: { phone: TEST_PHONE } });
      if (preexisting) {
        // Refuse rather than adopt it: an account already here means the
        // configured number is real, and these cases mutate its role.
        throw new Error(
          `${TEST_PHONE} already exists. This suite must run against a synthetic ` +
            "number (see npm run test:demo-account), never a deployment's real demo account."
        );
      }
    }
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    if (createdIds.length > 0) {
      await prisma.user.deleteMany({ where: { id: { in: createdIds } } });
    }
  });

  /** Records whatever the bypass just created so afterAll can remove it. */
  async function trackCreated(phone: string): Promise<void> {
    const u = await prisma.user.findUnique({ where: { phone }, select: { id: true } });
    if (u && !createdIds.includes(u.id)) createdIds.push(u.id);
  }

  async function reset(role: "user" | "admin" | "superadmin" | null): Promise<void> {
    await prisma.user.deleteMany({ where: { id: { in: createdIds }, phone: TEST_PHONE } });
    const idx = createdIds.findIndex(() => true);
    if (idx !== -1) createdIds.splice(idx, 1);
    if (role) {
      const u = await prisma.user.create({ data: { phone: TEST_PHONE, name: "Demo", role } });
      createdIds.push(u.id);
    }
  }

  const send = (phone: string) =>
    app.inject({ method: "POST", url: "/api/v1/auth/otp/send", payload: { phone } });

  const verify = (phone: string, code: string, name?: string) =>
    app.inject({
      method: "POST",
      url: "/api/v1/auth/otp/verify",
      payload: { phone, code, ...(name ? { name } : {}) },
    });

  it.runIf(enabled)("accepts the fixed code and creates a plain user", async () => {
    await reset(null);
    const res = await verify(TEST_PHONE, TEST_CODE, "Reviewer");
    await trackCreated(TEST_PHONE);

    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.user.phone).toBe(TEST_PHONE);
    expect(body.user.role).toBe("user");
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
  });

  it.runIf(enabled)("rejects any other code for that number", async () => {
    await reset(null);
    const wrong = TEST_CODE === "000000" ? "111111" : "000000";
    const res = await verify(TEST_PHONE, wrong);
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("OTP_INVALID");
  });

  // The bypass must be scoped to exactly one number. If the fixed code worked
  // anywhere else, a published credential would log in as anybody.
  it.runIf(enabled)("does not accept the fixed code for a different number", async () => {
    const other = `+9936${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const res = await verify(other, TEST_CODE, "Someone Else");
    expect(res.statusCode).toBe(401);
    await prisma.user.deleteMany({ where: { phone: other } });
  });

  // THE important one. A published, permanent code must never authenticate a
  // privileged account, however that account came to be privileged.
  it.runIf(enabled)("REFUSES the fixed code once the account is privileged", async () => {
    for (const role of ["admin", "superadmin"] as const) {
      await reset(role);
      const res = await verify(TEST_PHONE, TEST_CODE);
      expect(res.statusCode, `role ${role} must be refused`).toBe(403);
      expect(res.json().error).toBe("TEST_PHONE_NOT_PERMITTED");
    }
    await reset(null);
  });

  // No SMS is sent and no otp_codes row is written, so the per-phone resend
  // cooldown never engages — a reviewer tapping "resend" must not be locked out
  // for a minute.
  it.runIf(enabled)("send is a no-op that never hits the cooldown", async () => {
    for (let i = 0; i < 3; i++) {
      const res = await send(TEST_PHONE);
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({ ok: true });
    }
  });

  it("has a well-formed configuration", () => {
    // Both blank disables the bypass entirely, which is what a production
    // config should normally look like. If it IS set, the code has to be six
    // digits or the verify route would reject it before the bypass ever ran.
    if (!enabled) {
      expect(TEST_PHONE).toBe("");
      expect(TEST_CODE).toBe("");
    } else {
      expect(TEST_CODE).toMatch(/^\d{6}$/);
    }
  });
});
