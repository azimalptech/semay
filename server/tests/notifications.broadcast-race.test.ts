import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { prisma } from "../src/db.js";
import { broadcastToAllUsers } from "../src/notifications/service.js";
import { bindPushLogger } from "../src/notifications/push.js";
import { cleanupUsers, createUserWithToken } from "./helpers.js";

// One account deleted mid fan-out must not cost everybody else the
// announcement. broadcastToAllUsers reads every user id, then writes
// user_notifications rows for them in chunks — and user_notifications.userId
// is a real FK (prisma/schema.prisma, onDelete: Cascade). A user who
// disappears between the read and the write used to fail the WHOLE createMany
// with P2003, which lib/errors.ts answers with 409 CONSTRAINT_VIOLATION: the
// admin sees an error and NOT ONE user gets the announcement. That is a real
// production hole (an account deletion during a 100K fan-out) and it also
// showed up here as an intermittent 409 in notifications.broadcast.test.ts
// whenever another file's afterAll deleted its fixtures at the wrong instant.
//
// insertChunk now writes with INSERT … SELECT FROM users, so a missing (or
// soft-deleted) id simply selects no row — no FK to violate and no retry loop
// to get the count of. What this test pins is the OUTCOME: the survivor still
// gets the row, the request does not fail, `sent` counts rows written rather
// than ids attempted, and the skip is logged.
//
// The race is made deterministic by handing the fan-out ONE id that is not in
// the table: the first user.findMany is the recipient list, and a deleted user
// is indistinguishable from an id that never existed.
describe("broadcastToAllUsers survives a recipient deleted mid fan-out", () => {
  let recipientId: string;
  const title = `__TEST_FIXTURE__ race ${Math.random().toString(36).slice(2)}`;
  const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };

  beforeAll(async () => {
    bindPushLogger(log);
    recipientId = (await createUserWithToken("user")).userId;
  });

  afterAll(async () => {
    await prisma.userNotification.deleteMany({ where: { title } });
    await cleanupUsers([recipientId]);
    vi.restoreAllMocks();
  });

  it("still writes the inbox row for everyone who is still there", async () => {
    const real = prisma.user.findMany.bind(prisma.user);
    let first = true;
    // What the fan-out was handed, captured from the mock rather than counted
    // separately: another file creating or deleting a fixture between the two
    // reads would otherwise make this test's own arithmetic wrong.
    let listed = 0;
    const spy = vi
      .spyOn(prisma.user, "findMany")
      .mockImplementation(async (args?: Parameters<typeof real>[0]) => {
        const rows = (await real(args)) as { id: string }[];
        if (!first) return rows;
        first = false;
        const withPhantom = [...rows, { id: "00000000-0000-4000-8000-00000000dead" }];
        listed = withPhantom.length;
        return withPhantom;
      });

    const result = await broadcastToAllUsers(title, "body");
    expect(result.failed).toBe(0);
    // The phantom id got no row, so `sent` is short of what was listed — the
    // panel's count is recipients reached, not ids attempted. Strictly fewer,
    // not exactly one fewer: the suite runs files in parallel and another
    // file's afterAll may legitimately drop a fixture in the same window.
    expect(result.sent).toBeLessThan(listed);
    // Deliberately NOT compared against a live count(title): cleanupUsers in
    // another file's afterAll cascades user_notifications away, so the table
    // shrinks under us. `sent` is what the fan-out wrote, which is the claim.

    const row = await prisma.userNotification.findFirst({ where: { userId: recipientId, title } });
    expect(row).not.toBeNull();
    // info, not warn: the skip is the designed outcome of insertChunk, not a
    // fault (notifications/service.ts). The line still has to carry both
    // numbers, which is the whole reason it exists — `sent` alone cannot be
    // reconciled against the list it came from.
    expect(log.info).toHaveBeenCalledWith(
      expect.objectContaining({ listed, written: result.sent }),
      "broadcast: recipient(s) deleted mid fan-out, skipped"
    );
    spy.mockRestore();
  });
});
