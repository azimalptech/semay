import type { Language } from "@prisma/client";
import type { FastifyBaseLogger } from "fastify";
import type { MulticastMessage } from "firebase-admin/messaging";

import { prisma } from "../db.js";
import { copyFor, DEFAULT_LANGUAGE, type Copy } from "../lib/copy.js";
import { getFcmDisabledReason, getFcmMessaging } from "../lib/firebaseAdmin.js";

const DEAD_TOKEN_ERROR_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
  "messaging/invalid-argument", // malformed token — a real device token never hits this, a stale/fake one does
]);

export interface PushResult {
  sent: number;
  failed: number;
}

/** False when FCM isn't configured (no service account — dev boxes, CI, the
 * test suite). For the iOS badge-only correction (chats/service.ts
 * syncLauncherBadges), which is not a notification and may skip its
 * aggregation silently. A path that would have shown a notification must NOT
 * gate on this: it has to reach sendPushToUsers so the drop is logged. */
export function isPushEnabled(): boolean {
  return getFcmMessaging() !== undefined;
}

export type PushLogger = Pick<FastifyBaseLogger, "info" | "warn" | "error">;

// The services that send push have no request in hand (a broadcast's fan-out
// outlives its request on purpose; a chat push runs after the transaction), so
// index.ts binds the process logger here at boot. Silent until then — the test
// suite binds a spy when it wants to assert on what was logged.
let log: PushLogger = { info() {}, warn() {}, error() {} };

export function bindPushLogger(logger: PushLogger): void {
  log = logger;
}

export function pushLogger(): PushLogger {
  return log;
}

// A push-less deployment used to fail in silence: sendPushToUsers answered
// {0,0}, the broadcast route reported "sent: 25", and nothing after the boot
// line said a push was ever skipped — which is how "broadcasts only show up
// after reopening the app" went undiagnosed. Warned here, where every push
// path converges, but at most once a minute: the order path fires per order,
// and one line per skipped push would bury the rest of the log.
const SKIP_WARN_INTERVAL_MS = 60_000;
let lastSkipWarnAt = 0;
let skippedSinceWarn = 0;

function warnPushSkipped(recipients: number): void {
  skippedSinceWarn += 1;
  const now = Date.now();
  if (now - lastSkipWarnAt < SKIP_WARN_INTERVAL_MS) return;
  log.warn(
    { reason: getFcmDisabledReason(), recipients, skipped: skippedSinceWarn },
    "push skipped: FCM disabled"
  );
  lastSkipWarnAt = now;
  skippedSinceWarn = 0;
}

/** Presentation hints for a push. Everything here is optional — the order path
 * passes none and gets the plain title/body it always did. Chat messages pass
 * a channel, a tag and wakeApp so the OS treats them like a messenger would;
 * broadcasts pass a channel and a tag (notifications/service.ts).
 *
 * There is deliberately no sound option: every push type rings with the
 * device's DEFAULT notification sound (`sound: "default"` below, on both
 * platforms). A bundled chat sound was tried and removed at the owner's
 * request — see docs/08_OPERATIONS.md §3b. */
export interface PushOptions {
  /** Android notification channel. Must already exist on the device — the app
   * creates `chat_messages`, `announcements` and `orders` at
   * IMPORTANCE_HIGH in SemayApplication.kt, which is what makes a message pop as
   * a heads-up banner with sound instead of landing silently in the shade
   * under FCM's default "Miscellaneous" channel. An unknown id (an app older
   * than the channel) falls back to the manifest default, `chat_messages`
   * — the chat channel, which is why an order notice must name its own. */
  channelId?: string;
  /** Collapses notifications per conversation: Android `tag` (a newer
   * notification with the same tag REPLACES the older one, so five messages
   * from one chat are one entry, not five), iOS `thread-id` (groups them). */
  tag?: string;
  /** Per-recipient launcher badge — iOS app-icon number, Android
   * notificationCount. Recipients absent from the map get no badge field. */
  badgeByUser?: Map<string, number>;
  /** iOS `content-available`: wake the app briefly in the background so its
   * handler can act on the push (chat messages post the delivered receipt).
   * Opt-in, because it costs every backgrounded install a wake-up — a
   * broadcast or an order notice has nothing for the app to do. */
  wakeApp?: boolean;
}

/** Sends to every registered token for the given users. A no-op — logged, see
 * warnPushSkipped — if FCM isn't configured (see firebaseAdmin.ts), and a
 * silent one if none of them have a token; push is best-effort and must never
 * fail the caller's actual mutation.
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

interface TokenRow {
  userId: string;
  token: string;
  platform: string | null;
}

async function tokensForUsers(userIds: string[]): Promise<TokenRow[]> {
  const tokens: TokenRow[] = [];
  for (const idChunk of chunk(userIds, DB_IN_CHUNK)) {
    const rows = await prisma.userFcmToken.findMany({
      where: { userId: { in: idChunk } },
      select: { userId: true, token: true, platform: true },
    });
    tokens.push(...rows);
  }
  return tokens;
}

/** Runs one multicast per ≤500-token batch, tallies the result and prunes the
 * tokens FCM reports as dead (uninstalled app, cleared data, etc.) — the same
 * cleanup the old Cloud Functions push path did on a failed send. */
async function multicast(
  tokens: string[],
  build: (batch: string[]) => MulticastMessage
): Promise<PushResult> {
  const messaging = getFcmMessaging();
  if (!messaging || tokens.length === 0) return { sent: 0, failed: 0 };

  let sent = 0;
  let failed = 0;
  const deadTokens: string[] = [];
  for (const batch of chunk(tokens, FCM_MULTICAST_MAX)) {
    const res = await messaging.sendEachForMulticast(build(batch));
    sent += res.successCount;
    failed += res.failureCount;
    res.responses.forEach((r, i) => {
      const token = batch[i];
      if (token && !r.success && r.error && DEAD_TOKEN_ERROR_CODES.has(r.error.code)) {
        deadTokens.push(token);
      }
    });
  }

  for (const deadChunk of chunk(deadTokens, DB_IN_CHUNK)) {
    await prisma.userFcmToken.deleteMany({ where: { token: { in: deadChunk } } });
  }

  return { sent, failed };
}

/** Groups tokens by the badge their owner should show, so every recipient gets
 * their own count while a group with the same count still shares one
 * multicast. Recipients without an entry go in the `undefined` group. */
function groupByBadge(rows: TokenRow[], badgeByUser?: Map<string, number>): Map<number | undefined, string[]> {
  const groups = new Map<number | undefined, string[]>();
  for (const row of rows) {
    const badge = badgeByUser?.get(row.userId);
    let list = groups.get(badge);
    if (!list) {
      list = [];
      groups.set(badge, list);
    }
    list.push(row.token);
  }
  return groups;
}

export async function sendPushToUsers(
  userIds: string[],
  title: string,
  body: string,
  data?: Record<string, string>,
  opts: PushOptions = {}
): Promise<PushResult> {
  if (userIds.length === 0) return { sent: 0, failed: 0 };
  if (!getFcmMessaging()) {
    warnPushSkipped(userIds.length);
    return { sent: 0, failed: 0 };
  }

  const rows = await tokensForUsers(userIds);
  if (rows.length === 0) return { sent: 0, failed: 0 };

  const result: PushResult = { sent: 0, failed: 0 };
  for (const [badge, tokens] of groupByBadge(rows, opts.badgeByUser)) {
    const r = await multicast(tokens, (batch) => ({
      tokens: batch,
      notification: { title, body },
      data,
      android: {
        // High priority is what lets the message wake a dozing device and show
        // immediately, the way every messenger's notifications do; the default
        // ("normal") may be batched by the OS for minutes.
        priority: "high",
        notification: {
          sound: "default",
          ...(opts.channelId ? { channelId: opts.channelId } : {}),
          ...(opts.tag ? { tag: opts.tag } : {}),
          ...(badge !== undefined ? { notificationCount: badge } : {}),
        },
      },
      apns: {
        headers: { "apns-priority": "10" },
        payload: {
          aps: {
            sound: "default",
            // With the remote-notification background mode, lets the app's
            // handler run (chat: post the delivered receipt) without the user
            // opening anything.
            ...(opts.wakeApp ? { contentAvailable: true } : {}),
            ...(badge !== undefined ? { badge } : {}),
            ...(opts.tag ? { threadId: opts.tag } : {}),
          },
        },
      },
    }));
    result.sent += r.sent;
    result.failed += r.failed;
  }
  return result;
}

/** The same send, with the title and body written in each recipient's own
 * language (`users.language`, tk or ru — the product ships no English, see
 * lib/copy.ts).
 *
 * The notification payload carries ONE title/body for the whole multicast, so
 * the recipients are grouped by language and each group gets its own send —
 * two at most. `opts` is shared: `badgeByUser` is a per-user map, so it keeps
 * working across the split, and `tag`/`channelId`/sounds do not vary by
 * language. A recipient with no row (deleted between lookup and send) falls
 * back to Turkmen rather than being dropped.
 *
 * Callers here pass a handful of ids (the admins of one store, the
 * superadmins); a fan-out the size of a broadcast should keep using
 * sendPushToUsers with copy the superadmin typed. */
export async function sendLocalizedPushToUsers(
  userIds: string[],
  text: (copy: Copy) => { title: string; body: string },
  data?: Record<string, string>,
  opts: PushOptions = {}
): Promise<PushResult> {
  if (userIds.length === 0) return { sent: 0, failed: 0 };

  const rows = await prisma.user.findMany({
    where: { id: { in: userIds } },
    select: { id: true, language: true },
  });
  const languageOf = new Map(rows.map((r) => [r.id, r.language]));

  const groups = new Map<Language, string[]>();
  for (const id of userIds) {
    const language = languageOf.get(id) ?? DEFAULT_LANGUAGE;
    const list = groups.get(language);
    if (list) list.push(id);
    else groups.set(language, [id]);
  }

  const result: PushResult = { sent: 0, failed: 0 };
  for (const [language, ids] of groups) {
    const { title, body } = text(copyFor(language));
    const r = await sendPushToUsers(ids, title, body, data, opts);
    result.sent += r.sent;
    result.failed += r.failed;
  }
  return result;
}

/** iOS-only badge correction with no banner. Sent after the recipient reads a
 * thread, so the app-icon number drops back in step with what they have
 * actually read — an APNs payload carrying only `badge` updates the icon and
 * shows nothing. Android launchers derive their count from the notifications
 * themselves (which the app clears on open), so there is nothing to send. */
export async function sendBadgeUpdate(badgeByUser: Map<string, number>): Promise<void> {
  if (badgeByUser.size === 0) return;
  if (!getFcmMessaging()) return;

  const rows = (await tokensForUsers([...badgeByUser.keys()])).filter((r) => r.platform === "ios");
  if (rows.length === 0) return;

  for (const [badge, tokens] of groupByBadge(rows, badgeByUser)) {
    if (badge === undefined) continue;
    await multicast(tokens, (batch) => ({
      tokens: batch,
      apns: {
        headers: { "apns-priority": "10" },
        payload: { aps: { badge } },
      },
    }));
  }
}
