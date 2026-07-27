import { prisma } from "../db.js";
import { getFcmMessaging } from "../lib/firebaseAdmin.js";

const DEAD_TOKEN_ERROR_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
  "messaging/invalid-argument", // malformed token — a real device token never hits this, a stale/fake one does
]);

export interface PushResult {
  sent: number;
  failed: number;
}

/** Sends to every registered token for the given users. Silently a no-op if
 * FCM isn't configured (see firebaseAdmin.ts) or none of them have a token —
 * push is best-effort and must never fail the caller's actual mutation.
 * sent/failed count per-token (a user can have multiple devices), matching
 * FCM's own multicast response shape. */
// FCM's sendEachForMulticast rejects more than 500 tokens per call, and a huge
// `IN (...)` is its own problem — so token fetch, multicast, and dead-token
// pruning are all chunked. Without this, a broadcast to a large audience (aim:
// 100K users) throws on the very first send instead of delivering.
const FCM_MULTICAST_MAX = 500;
const DB_IN_CHUNK = 1000;

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

export async function sendPushToUsers(
  userIds: string[],
  title: string,
  body: string,
  data?: Record<string, string>
): Promise<PushResult> {
  if (userIds.length === 0) return { sent: 0, failed: 0 };
  const messaging = getFcmMessaging();
  if (!messaging) return { sent: 0, failed: 0 };

  const tokens: string[] = [];
  for (const idChunk of chunk(userIds, DB_IN_CHUNK)) {
    const rows = await prisma.userFcmToken.findMany({
      where: { userId: { in: idChunk } },
      select: { token: true },
    });
    for (const r of rows) tokens.push(r.token);
  }
  if (tokens.length === 0) return { sent: 0, failed: 0 };

  let sent = 0;
  let failed = 0;
  const deadTokens: string[] = [];
  for (const batch of chunk(tokens, FCM_MULTICAST_MAX)) {
    const res = await messaging.sendEachForMulticast({ tokens: batch, notification: { title, body }, data });
    sent += res.successCount;
    failed += res.failureCount;
    res.responses.forEach((r, i) => {
      const token = batch[i];
      if (token && !r.success && r.error && DEAD_TOKEN_ERROR_CODES.has(r.error.code)) {
        deadTokens.push(token);
      }
    });
  }

  // Prune tokens FCM reports as dead (uninstalled app, cleared data, etc.) —
  // same cleanup the old Cloud Functions push path did on a failed send.
  for (const deadChunk of chunk(deadTokens, DB_IN_CHUNK)) {
    await prisma.userFcmToken.deleteMany({ where: { token: { in: deadChunk } } });
  }

  return { sent, failed };
}
