import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { hashPassword } from "../src/auth/superadminAuth.js";
import { prisma } from "../src/db.js";
import { type App } from "./helpers.js";

// Password login for the Super Admin panel, at the owner's explicit request —
// see auth/superadminAuth.ts. Every rejection reason (wrong password, unknown
// phone, a real non-superadmin account, no password set) must look identical to
// the caller: a differentiated error or response-time gap would let an attacker
// enumerate which phone numbers exist or hold the superadmin role.
describe("POST /auth/superadmin/login", () => {
  let app: App;
  const userIds: string[] = [];

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  async function makePhone(): Promise<string> {
    return `+9936${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
  }

  it("logs in with the correct phone and password", async () => {
    const phone = await makePhone();
    const passwordHash = await hashPassword("correct-horse-battery-staple");
    const user = await prisma.user.create({ data: { phone, role: "superadmin", passwordHash } });
    userIds.push(user.id);

    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone, password: "correct-horse-battery-staple" },
    });

    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
    expect(body.user.role).toBe("superadmin");
  });

  it("rejects the wrong password with a generic error", async () => {
    const phone = await makePhone();
    const passwordHash = await hashPassword("the-real-password");
    const user = await prisma.user.create({ data: { phone, role: "superadmin", passwordHash } });
    userIds.push(user.id);

    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone, password: "not-the-real-password" },
    });

    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("INVALID_CREDENTIALS");
  });

  it("rejects a real account that is not superadmin, even with the right password", async () => {
    const phone = await makePhone();
    const passwordHash = await hashPassword("a-real-password");
    // A plain user somehow having a passwordHash set should still never be able
    // to use this login — role is checked independently of password match.
    const user = await prisma.user.create({ data: { phone, role: "user", passwordHash } });
    userIds.push(user.id);

    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone, password: "a-real-password" },
    });

    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("INVALID_CREDENTIALS");
  });

  it("rejects a superadmin with no password set (never issued one)", async () => {
    const phone = await makePhone();
    const user = await prisma.user.create({ data: { phone, role: "superadmin" } });
    userIds.push(user.id);

    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone, password: "anything-at-all" },
    });

    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("INVALID_CREDENTIALS");
  });

  it("rejects an unknown phone number with the SAME error as a wrong password", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone: "+99369999999", password: "whatever" },
    });

    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("INVALID_CREDENTIALS");
  });

  it("never leaks a passwordHash in the response body", async () => {
    const phone = await makePhone();
    const passwordHash = await hashPassword("secret123");
    const user = await prisma.user.create({ data: { phone, role: "superadmin", passwordHash } });
    userIds.push(user.id);

    const res = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone, password: "secret123" },
    });

    expect(JSON.stringify(res.json())).not.toContain("passwordHash");
    expect(JSON.stringify(res.json())).not.toContain("$2");
  });
});
