import { Prisma } from "@prisma/client";
import { describe, expect, it } from "vitest";

import { withRetry } from "../src/lib/withRetry.js";

// withRetry is the seam every contended write in the product goes through
// (posts.setToggle, chats.sendMessage, orders, auth.rotateSession, the
// maintenance reaper). What may and may not be retried is a correctness
// question — a retry is only ever safe when NO statement of the transaction
// reached the database — so it is pinned here rather than inferred from the
// call sites.
//
// The case that forced this file: under parallel load the release gate lost
// whole files to "Transaction API error: Unable to start a transaction in the
// given time." Prisma raises that when its 2 s `maxWait` elapses before a
// pooled connection comes free, i.e. BEFORE BEGIN — the same thing a hot post
// does to the pool in production (docs/08_OPERATIONS.md §7: 50 simultaneous
// likes on one post), where it surfaced as HTTP 500 on a like and, on
// /auth/refresh, as a logout.

function knownError(code: string, message: string): Prisma.PrismaClientKnownRequestError {
  return new Prisma.PrismaClientKnownRequestError(message, { code, clientVersion: "test" });
}

/** Fails `failures` times with `err`, then succeeds. Returns the call count. */
function failThen(failures: number, err: unknown): { run: () => Promise<string>; calls: () => number } {
  let calls = 0;
  return {
    run: async () => {
      calls += 1;
      if (calls <= failures) throw err;
      return "ok";
    },
    calls: () => calls,
  };
}

describe("withRetry: only re-runs transactions that never ran", () => {
  it("retries a write conflict / deadlock (P2034)", async () => {
    const f = failThen(3, knownError("P2034", "Transaction failed due to a write conflict or a deadlock"));
    await expect(f.run()).rejects.toThrow(); // first call, consumed
    await expect(withRetry(f.run)).resolves.toBe("ok");
    expect(f.calls()).toBe(4);
  });

  it("retries a transaction the pool never started (P2028 maxWait)", async () => {
    const f = failThen(1, knownError("P2028", "Transaction API error: Unable to start a transaction in the given time."));
    await expect(withRetry(f.run)).resolves.toBe("ok");
    expect(f.calls()).toBe(2);
  });

  it("retries a connection-pool timeout (P2024)", async () => {
    const f = failThen(1, knownError("P2024", "Timed out fetching a new connection from the connection pool."));
    await expect(withRetry(f.run)).resolves.toBe("ok");
    expect(f.calls()).toBe(2);
  });

  it("gives an acquire timeout a small budget — it has already cost its own maxWait", async () => {
    // Eight attempts x 2 s of maxWait would turn a saturated pool into a 16 s
    // request, so these stop at three and surface the original error.
    const f = failThen(99, knownError("P2028", "Transaction API error: Unable to start a transaction in the given time."));
    await expect(withRetry(f.run)).rejects.toMatchObject({ code: "P2028" });
    expect(f.calls()).toBe(3);
  });

  it("does NOT retry the other P2028 — an execution timeout means statements ran", async () => {
    // Same Prisma code, opposite meaning: this one fires after BEGIN, with
    // work already done and possibly committed by a sibling. Re-running it
    // blind is how a counter gets incremented twice.
    const f = failThen(99, knownError("P2028", "Transaction API error: Transaction already closed: A query cannot be executed on an expired transaction."));
    await expect(withRetry(f.run)).rejects.toMatchObject({ code: "P2028" });
    expect(f.calls()).toBe(1);
  });

  it("does not retry an ordinary failure, and propagates it unchanged", async () => {
    const boom = new Error("not a transaction problem");
    const f = failThen(99, boom);
    await expect(withRetry(f.run)).rejects.toBe(boom);
    expect(f.calls()).toBe(1);
  });

  it("returns without retrying when the first attempt succeeds", async () => {
    const f = failThen(0, new Error("unused"));
    await expect(withRetry(f.run)).resolves.toBe("ok");
    expect(f.calls()).toBe(1);
  });
});
