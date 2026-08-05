import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { hashPassword } from "../src/auth/superadminAuth.js";
import { prisma } from "../src/db.js";
import { authHeader, refreshedToken, TEST_FIXTURE_NAME, type App } from "./helpers.js";

// Until this route existed the superadmin password could only be changed with a
// direct UPDATE against the database, so in practice it never was — the account
// was still on its seeded value.
describe("POST /auth/superadmin/change-password", () => {
  let app: App;
  const userIds: string[] = [];

  const OLD = "old-password-1234";
  const NEW = "new-password-5678";

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  async function makeSuperadmin(password: string) {
    const phone = `+9937${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const user = await prisma.user.create({
      data: {
        phone,
        role: "superadmin",
        name: TEST_FIXTURE_NAME,
        passwordHash: await hashPassword(password),
      },
    });
    userIds.push(user.id);
    return { user, token: await refreshedToken(user.id) };
  }

  const change = (token: string, body: Record<string, unknown>) =>
    app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/change-password",
      headers: authHeader(token),
      payload: body,
    });

  it("changes the password and makes the new one work", async () => {
    const { user, token } = await makeSuperadmin(OLD);

    const res = await change(token, { currentPassword: OLD, newPassword: NEW });
    expect(res.statusCode).toBe(200);

    const login = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone: user.phone, password: NEW },
    });
    expect(login.statusCode).toBe(200);
  });

  it("stops the OLD password working", async () => {
    const { user, token } = await makeSuperadmin(OLD);
    await change(token, { currentPassword: OLD, newPassword: NEW });

    const login = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone: user.phone, password: OLD },
    });
    expect(login.statusCode).toBe(401);
  });

  it("requires the current password — a stolen access token alone is not enough", async () => {
    const { user, token } = await makeSuperadmin(OLD);

    const res = await change(token, { currentPassword: "not-the-password", newPassword: NEW });
    expect(res.statusCode).toBe(401);

    // Unchanged.
    const login = await app.inject({
      method: "POST",
      url: "/api/v1/auth/superadmin/login",
      payload: { phone: user.phone, password: OLD },
    });
    expect(login.statusCode).toBe(200);
  });

  it("rejects a new password under 12 characters", async () => {
    const { token } = await makeSuperadmin(OLD);
    const res = await change(token, { currentPassword: OLD, newPassword: "short123" });
    expect(res.statusCode).toBe(400);
  });

  it("kills every existing session, so a leaked token can't outlive the change", async () => {
    const { user, token } = await makeSuperadmin(OLD);
    await prisma.session.create({
      data: {
        userId: user.id,
        tokenHash: `stale-${Date.now()}`,
        expiresAt: new Date(Date.now() + 86_400_000),
      },
    });

    await change(token, { currentPassword: OLD, newPassword: NEW });

    expect(await prisma.session.count({ where: { userId: user.id } })).toBe(0);
  });

  it("is superadmin-only", async () => {
    const phone = `+9937${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const plain = await prisma.user.create({
      data: { phone, name: TEST_FIXTURE_NAME, passwordHash: await hashPassword(OLD) },
    });
    userIds.push(plain.id);

    const res = await change(await refreshedToken(plain.id), {
      currentPassword: OLD,
      newPassword: NEW,
    });
    expect(res.statusCode).toBe(403);
  });
});
