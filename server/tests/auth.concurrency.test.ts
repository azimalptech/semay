import { afterAll, describe, expect, it } from "vitest";

import { findOrCreateUserByPhone } from "../src/auth/users.js";
import { prisma } from "../src/db.js";

// Regression test for the bug the old Firestore backend patched with a
// deterministic sha256(phone)-derived uid: under concurrent signup for the
// SAME brand-new phone number, exactly one user row must ever exist. MySQL's
// `users.phone UNIQUE` + insert/re-select-on-conflict (findOrCreateUserByPhone)
// is the new lock; this test would fail (>1 row) if that logic regressed.
describe("findOrCreateUserByPhone concurrency", () => {
  const phone = `+9936${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;

  afterAll(async () => {
    await prisma.user.deleteMany({ where: { phone } });
    await prisma.$disconnect();
  });

  it("creates exactly one user row when many parallel calls race for the same new phone", async () => {
    const CONCURRENCY = 20;

    const results = await Promise.all(
      Array.from({ length: CONCURRENCY }, () => findOrCreateUserByPhone(phone, "Concurrency Test"))
    );

    const distinctIds = new Set(results.map((u) => u.id));
    expect(distinctIds.size).toBe(1);

    const rowCount = await prisma.user.count({ where: { phone } });
    expect(rowCount).toBe(1);
  });
});
