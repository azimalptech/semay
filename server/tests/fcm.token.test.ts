import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { registerFcmToken } from "../src/users/service.js";

// The app fires token sync from more than one place at launch, so several
// requests with the SAME token land concurrently. Prisma's upsert isn't atomic,
// so that used to surface as a P2002 500 on the device. This proves the
// register path is now idempotent under a concurrent burst and still reassigns
// ownership on reinstall/relogin.
describe("FCM token registration (concurrent, idempotent)", () => {
  let userA: string;
  let userB: string;
  const token = `tok-${Date.now()}-${Math.random().toString(36).slice(2)}`;

  beforeAll(async () => {
    const a = await prisma.user.create({
      data: { phone: `+9939${Math.floor(1_000_000 + Math.random() * 8_999_999)}` },
    });
    const b = await prisma.user.create({
      data: { phone: `+9939${Math.floor(1_000_000 + Math.random() * 8_999_999)}` },
    });
    userA = a.id;
    userB = b.id;
  });

  afterAll(async () => {
    await prisma.userFcmToken.deleteMany({ where: { token } });
    await prisma.user.deleteMany({ where: { id: { in: [userA, userB] } } });
  });

  it("a burst of concurrent same-token registrations never throws and leaves one row", async () => {
    await Promise.all(
      Array.from({ length: 10 }, () => registerFcmToken(userA, token, "android"))
    );
    const rows = await prisma.userFcmToken.findMany({ where: { token } });
    expect(rows.length).toBe(1);
    expect(rows[0].userId).toBe(userA);
  });

  it("re-registering the same token under a different user reassigns ownership", async () => {
    await registerFcmToken(userB, token, "ios");
    const rows = await prisma.userFcmToken.findMany({ where: { token } });
    expect(rows.length).toBe(1);
    expect(rows[0].userId).toBe(userB);
    expect(rows[0].platform).toBe("ios");
  });
});
