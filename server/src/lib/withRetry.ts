import { Prisma } from "@prisma/client";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** MySQL can deadlock (or report a write conflict) when multiple transactions
 * contend for the same row — e.g. several messages landing in the same chat
 * at once, each updating chats.lastMessageAt/unreadBy*. MySQL always rolls
 * one side back cleanly, so a retry is safe and expected, not a bug to work
 * around at the call site. Jittered backoff spreads out retries so a hot row
 * under heavy contention converges instead of the same N callers colliding
 * again on every attempt. */
export async function withRetry<T>(fn: () => Promise<T>, attempts = 8): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2034") {
        await sleep(5 + Math.random() * 20 * (i + 1));
        continue;
      }
      throw err;
    }
  }
  throw lastErr;
}
