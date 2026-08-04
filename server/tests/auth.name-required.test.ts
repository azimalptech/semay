import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { type App } from "./helpers.js";

// An account must never exist without a name. Previously verifyOtp created the
// row with name:'' and relied on the CLIENT to follow up with PATCH /users/me,
// so anything that interrupted that step (app killed, request failed, a
// non-app caller) left a permanently nameless account behind — the live
// database had accumulated 11 of them.
describe("signup requires a name", () => {
  let app: App;
  const phones: string[] = [];

  const mkPhone = () => {
    const p = `+9936${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    phones.push(p);
    return p;
  };

  async function sendOtp(phone: string): Promise<string> {
    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/otp/send",
      payload: { phone },
    });
    expect(res.statusCode).toBe(200);
    // OTP_DEV_MODE echoes the code; fall back to reading it if not.
    const devCode = res.json().devCode as string | undefined;
    if (devCode) return devCode;
    const row = await prisma.otpCode.findUniqueOrThrow({ where: { phone } });
    return row.code;
  }

  const verify = (payload: Record<string, unknown>) =>
    app.inject({ method: "POST", url: "/api/v1/auth/otp/verify", payload });

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.otpCode.deleteMany({ where: { phone: { in: phones } } });
    await prisma.user.deleteMany({ where: { phone: { in: phones } } });
  });

  it("refuses to create an account with no name, and creates NOTHING", async () => {
    const phone = mkPhone();
    const code = await sendOtp(phone);

    const res = await verify({ phone, code });

    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("NAME_REQUIRED");
    // The critical half: no half-formed row left behind.
    expect(await prisma.user.count({ where: { phone } })).toBe(0);
  });

  it("keeps the SAME code usable so the retry with a name succeeds", async () => {
    const phone = mkPhone();
    const code = await sendOtp(phone);

    const rejected = await verify({ phone, code });
    expect(rejected.json().error).toBe("NAME_REQUIRED");

    // Rejection rolls back the transaction, so the OTP row is NOT consumed —
    // the user isn't forced to request a second SMS just to give their name.
    const ok = await verify({ phone, code, name: "Aylar" });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().user.name).toBe("Aylar");

    const created = await prisma.user.findUniqueOrThrow({ where: { phone } });
    expect(created.name).toBe("Aylar");
  });

  it("rejects a blank / whitespace-only name", async () => {
    const phone = mkPhone();
    const code = await sendOtp(phone);

    expect((await verify({ phone, code, name: "" })).statusCode).toBe(400);
    expect((await verify({ phone, code, name: "   " })).statusCode).toBe(400);
    expect(await prisma.user.count({ where: { phone } })).toBe(0);
  });

  it("does not ask a RETURNING user for a name again", async () => {
    const phone = mkPhone();
    const first = await sendOtp(phone);
    expect((await verify({ phone, code: first, name: "Merdan" })).statusCode).toBe(200);

    // Second login, no name supplied — must simply succeed.
    const second = await sendOtp(phone);
    const res = await verify({ phone, code: second });
    expect(res.statusCode).toBe(200);
    expect(res.json().user.name).toBe("Merdan");
  });

  it("does not let a supplied name overwrite an existing account's name", async () => {
    const phone = mkPhone();
    const first = await sendOtp(phone);
    await verify({ phone, code: first, name: "Original" });

    const second = await sendOtp(phone);
    const res = await verify({ phone, code: second, name: "Impostor" });

    expect(res.statusCode).toBe(200);
    expect(res.json().user.name).toBe("Original");
  });

  it("still rejects a wrong code before ever considering the name", async () => {
    const phone = mkPhone();
    await sendOtp(phone);

    // A caller without a valid code must not be able to tell a registered
    // number from an unregistered one — the name check runs strictly after
    // code validation, so this is OTP_INVALID, never NAME_REQUIRED.
    const res = await verify({ phone, code: "000000", name: "Whoever" });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("OTP_INVALID");
  });
});
