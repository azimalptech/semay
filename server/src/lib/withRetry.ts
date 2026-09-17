import { Prisma } from "@prisma/client";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** MySQL rolled one side of a deadlock (or write conflict) back cleanly — the
 * transaction ran no statement that survived, so re-running it is safe. */
function isWriteConflict(err: unknown): boolean {
  return err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2034";
}

/** The transaction never BEGAN: Prisma gave up waiting for a free connection
 * from the pool. Two spellings of the same thing —
 *
 *   P2028 "Unable to start a transaction in the given time." — the interactive
 *         transaction's `maxWait` (2 s by default) elapsed before a connection
 *         came free. Matched on the message, deliberately: P2028 is Prisma's
 *         generic "Transaction API error", and its OTHER member is the
 *         execution `timeout`, where statements DID run — that one must not be
 *         retried blindly and is not matched here.
 *   P2024 — the same exhaustion one layer down (`pool_timeout` fetching a
 *         connection), again before any statement was sent.
 *
 * Neither is a product defect: they are what a pool looks like when many
 * callers queue on one hot row (docs/08_OPERATIONS.md §7 — 50 simultaneous
 * likes on one post is the measured case), and the transaction's own
 * `SELECT … FOR UPDATE` then makes each one hold its connection while it waits
 * its turn. Before this, the loser surfaced as HTTP 500: a like that failed for
 * being popular, and a `POST /auth/refresh` that answered 500 and logged the
 * device out. */
function isAcquireTimeout(err: unknown): boolean {
  if (!(err instanceof Prisma.PrismaClientKnownRequestError)) return false;
  if (err.code === "P2024") return true;
  return err.code === "P2028" && /unable to start a transaction/i.test(err.message);
}

/** An acquire timeout has already cost its own `maxWait` before it is thrown,
 * so it gets a much smaller budget than a deadlock: eight attempts would turn a
 * saturated pool into a 16 s request. Three bounds the worst case at ~6 s,
 * which is inside the client timeouts and long enough for a queue of a few
 * dozen writers on one row to drain. */
const ACQUIRE_ATTEMPTS = 3;

/** Retries the transactions that MySQL or the connection pool refused to run,
 * never the ones that ran and failed. Both retryable classes above are "no
 * statement of this transaction is in the database", which is what makes a
 * plain re-run correct rather than a workaround at the call site.
 *
 * Jittered backoff spreads out retries so a hot row under heavy contention
 * converges instead of the same N callers colliding again on every attempt. */
export async function withRetry<T>(fn: () => Promise<T>, attempts = 8): Promise<T> {
  let lastErr: unknown;
  let acquireTries = 0;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (isWriteConflict(err)) {
        await sleep(5 + Math.random() * 20 * (i + 1));
        continue;
      }
      if (isAcquireTimeout(err) && ++acquireTries < ACQUIRE_ATTEMPTS) {
        await sleep(25 + Math.random() * 75);
        continue;
      }
      throw err;
    }
  }
  throw lastErr;
}
