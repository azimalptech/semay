import {
  Prisma,
  type Chat,
  type Message,
  type MessageMediaType,
  type Role,
  type SenderRole,
} from "@prisma/client";

import { prisma } from "../db.js";
import { parseBigIntId } from "../lib/ids.js";
import type { AccessTokenPayload } from "../lib/jwt.js";
import { publish } from "../realtime/bus.js";
import { withRetry } from "../lib/withRetry.js";
import {
  isPushEnabled,
  sendBadgeUpdate,
  sendLocalizedPushToUsers,
  type PushOptions,
} from "../notifications/push.js";

export type ChatSide = "user" | "admin";

/** Android notification channel for chat pushes — created at IMPORTANCE_HIGH,
 * with no sound of its own, by the app's SemayApplication.kt, so the id here
 * and there must match. Chat messages ring with the phone's DEFAULT
 * notification sound, like every other push type (docs/08 §3b). */
const CHAT_PUSH_CHANNEL = "chat_messages";

export class ChatNotFoundError extends Error {
  constructor() {
    super("Chat not found");
  }
}

export class ChatForbiddenError extends Error {
  constructor() {
    super("Not a participant of this chat");
  }
}

/** Whoever is asking for a chat action — the access token's claims on a route,
 * the DB-refreshed ChannelAuthCtx on a socket subscribe. One shape so both
 * paths resolve the side through the same function and can never disagree
 * about what a subscriber is allowed to see. */
export interface ChatParticipant {
  userId: string;
  role: Role;
  storeIds: string[];
}

/** Which side of the conversation `who` is on for `chat` — null if neither
 * (used everywhere a route needs to authorize a chat action). Superadmin
 * counts as the admin side (read/moderate any chat, same as other admin-only
 * surfaces in this codebase). */
export function resolveChatSide(
  chat: Pick<Chat, "userId" | "storeId">,
  who: ChatParticipant
): ChatSide | null {
  if (who.userId === chat.userId) return "user";
  if (who.role === "superadmin") return "admin";
  if (who.role === "admin" && who.storeIds.includes(chat.storeId)) return "admin";
  return null;
}

export async function getChatForParticipant(
  chatId: string,
  auth: AccessTokenPayload
): Promise<{ chat: Chat; side: ChatSide }> {
  const chat = await prisma.chat.findUnique({ where: { id: chatId } });
  if (!chat) throw new ChatNotFoundError();
  const side = resolveChatSide(chat, { userId: auth.sub, role: auth.role, storeIds: auth.storeIds });
  if (!side) throw new ChatForbiddenError();
  return { chat, side };
}

/** Exclusive lower bound of what `side` may still see of this chat: the newest
 * message id that existed when that side last deleted it (hideChat), or null
 * when nothing is hidden. Every participant-facing read of messages composes
 * with this — thread, paging, socket snapshot, receipts, reply quoting. There
 * is no unfiltered participant read: superadmin resolves to the admin side
 * (resolveChatSide), so its delete writes the store's cutoff and a store
 * admin's delete bounds its reads in turn — the same "superadmin is the
 * store's side" rule the list channels and DELETE already follow. */
export function historyCutoff(chat: Chat, side: ChatSide): bigint | null {
  return side === "user" ? chat.hiddenByUserUpToId : chat.hiddenByAdminUpToId;
}

/** `rows` as `side` may see them: a quote of a hidden row is blanked. The other
 * side can still reply to a message this side deleted, and the reply carries
 * that message's text (replyToText) and id — the hidden history, verbatim, on
 * a row that is itself above the cutoff and therefore returned. Projected per
 * reader, never written back: the row keeps its quote for the side that can
 * see the original. The live upsert on chat:{id}:messages is one frame for
 * both sides and cannot be projected here, so the phone applies the same mask
 * when it knows the cutoff (chat_providers.dart). */
function withoutHiddenQuotes(rows: Message[], cutoff: bigint | null): Message[] {
  if (cutoff === null) return rows;
  return rows.map((m) =>
    m.replyToMessageId !== null && m.replyToMessageId <= cutoff
      ? { ...m, replyToMessageId: null, replyToText: null, replyToSenderRole: null }
      : m
  );
}

/** WHERE fragment for the rows of this chat that `side` may still see. A
 * caller that also constrains `id` (a paging cursor, a quoted message id)
 * must combine it with AND, never spread it: two `id` keys in one object are
 * not merged, the later one silently replaces the earlier — which turned
 * "this exact quoted message, if visible" into "any visible message". */
function visibleWhere(chat: Chat, side: ChatSide): Prisma.MessageWhereInput {
  const cutoff = historyCutoff(chat, side);
  return { chatId: chat.id, ...(cutoff !== null ? { id: { gt: cutoff } } : {}) };
}

// Deterministic id keeps createOrGetChat a plain idempotent create — no
// check-then-create race window like Firestore's !hasPendingWrites workaround
// needed (see docs/07_MIGRATION.md).
function chatId(userId: string, storeId: string): string {
  return `${userId}_${storeId}`;
}

/** Same insert-then-re-select-on-conflict idiom as findOrCreateUserByPhone —
 * plain `prisma.chat.upsert()` still round-trips through a SELECT-then-write
 * under the hood and threw raw unique-constraint errors under concurrent
 * first-time creation for the same user+store (two devices opening the same
 * chat at once). Try/catch on the PK is what's actually atomic on MySQL. */
export async function createOrGetChat(userId: string, storeId: string): Promise<Chat> {
  const id = chatId(userId, storeId);
  const existing = await prisma.chat.findUnique({ where: { id } });
  if (existing) return existing;

  return withRetry(async () => {
    try {
      return await prisma.chat.create({ data: { id, userId, storeId } });
    } catch (err) {
      if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
        const winner = await prisma.chat.findUnique({ where: { id } });
        if (winner) return winner;
      }
      throw err;
    }
  });
}

const HIDDEN_LIST_LIMIT = 100;

/** A chat reappears in the list once a new message arrives after it was
 * hidden — same "swipe-to-delete isn't permanent" behavior the mobile app
 * already had, now enforced by a single comparison instead of an unhide call. */
export async function listUserChats(userId: string): Promise<Chat[]> {
  const chats = await prisma.chat.findMany({
    where: { userId },
    orderBy: { lastMessageAt: "desc" },
    take: HIDDEN_LIST_LIMIT,
  });
  return chats.filter((c) => !c.hiddenByUserAt || (c.lastMessageAt && c.lastMessageAt > c.hiddenByUserAt));
}

export async function listStoreChats(storeId: string): Promise<Chat[]> {
  const chats = await prisma.chat.findMany({
    where: { storeId },
    orderBy: { lastMessageAt: "desc" },
    take: HIDDEN_LIST_LIMIT,
  });
  return chats.filter(
    (c) => !c.hiddenByAdminAt || (c.lastMessageAt && c.lastMessageAt > c.hiddenByAdminAt)
  );
}

function publishChatEverywhere(chat: Chat): void {
  publish(`chat:${chat.id}`, { type: "upsert", data: chat });
  publish(`user:${chat.userId}:chats`, { type: "upsert", data: chat });
  publish(`store:${chat.storeId}:chats`, { type: "upsert", data: chat });
}

export interface SendMessageInput {
  text?: string;
  mediaUrl?: string;
  mediaType?: MessageMediaType;
  orderId?: string;
  sharedPostId?: string;
  sharedStoryId?: string;
  replyToMessageId?: string;
  // Client-generated idempotency key (offline outbox). A retried send under
  // flaky signal reuses the same key, so the server returns the already-
  // created message instead of a duplicate.
  clientKey?: string;
}

/** Sends a message and updates the chat's denormalized last-message/unread
 * fields in one transaction — replaces the old async onMessageCreated
 * trigger with a same-request update, so there's no window where the chat
 * list is briefly stale relative to the message that just landed. */
export async function sendMessage(
  chat: Chat,
  side: ChatSide,
  senderId: string,
  input: SendMessageInput
): Promise<Message> {
  // Idempotency fast-path: if this clientKey already produced a message in
  // THIS chat, from THIS sender, return it unchanged (no second row, no
  // re-publish, no unread double-count).
  //
  // The chatId/senderId predicates are load-bearing, exactly as they are on the
  // replyToMessageId lookup below. clientKey is globally UNIQUE, so an unscoped
  // findUnique returned whatever row owned the key — including one from a
  // stranger's private chat, which the caller could not otherwise read (GET on
  // that chat correctly 403s). Replaying a key was a read primitive for another
  // user's message text, sender and timestamps.
  //
  // It was also silent data loss in the ordinary case: a key that collided with
  // a foreign row returned 201 while the caller's own message was never stored,
  // and the outbox drops an item on any 2xx.
  //
  // Scoping matches the documented intent — the same client retrying the same
  // send — and a genuine retry always carries the same chat and sender.
  if (input.clientKey) {
    const existing = await prisma.message.findFirst({
      where: { clientKey: input.clientKey, chatId: chat.id, senderId },
    });
    if (existing) return existing;
  }

  const senderRole: SenderRole = side;
  const preview = (input.text || (input.mediaUrl ? "[media]" : "")).slice(0, 512);

  let replyToText: string | null = null;
  let replyToSenderRole: SenderRole | null = null;
  let replyToMessageId: bigint | null = null;
  const requestedReplyTo = parseBigIntId(input.replyToMessageId);
  if (requestedReplyTo !== undefined) {
    // `chatId: chat.id` in the WHERE is load-bearing, not defensive noise: this
    // copies the quoted message's text onto the new message, which is then
    // returned to the sender. Looking it up by id ALONE let any authenticated
    // user quote any message in the database from inside their own chat and
    // read back the first 512 chars — and message ids are sequential BIGINTs,
    // so every private conversation in the system could be walked by simply
    // incrementing the id. Scoping the lookup to this chat makes an
    // out-of-chat id return nothing, exactly like a deleted one — and
    // visibleWhere extends "this chat" to "this chat as the sender may still
    // see it": a message below their own hide cutoff is gone for them, so it
    // cannot be quoted back into view either.
    const replyTo = await prisma.message.findFirst({
      where: { AND: [{ id: requestedReplyTo }, visibleWhere(chat, side)] },
      select: { id: true, text: true, senderRole: true },
    });
    if (replyTo) {
      replyToMessageId = replyTo.id;
      replyToText = replyTo.text.slice(0, 512);
      replyToSenderRole = replyTo.senderRole;
    }
    // A non-match falls through with all three left null — the message still
    // sends, just without the quote, rather than 4xx-ing on a race where the
    // quoted message was deleted between the client rendering it and sending.
  }

  let txResult;
  try {
    txResult = await withRetry(() => prisma.$transaction(async (tx) => {
    // Take the chat row's exclusive lock UP FRONT, before the INSERT.
    //
    // Without this, two messages landing in the same chat deadlock roughly once
    // per 1500 concurrent sends — confirmed against MySQL's own LATEST DETECTED
    // DEADLOCK report, not inferred. The mechanism: `messages_chatId_fkey`
    // makes the INSERT take a SHARED lock on the parent chats row, and the
    // UPDATE below then needs that same row EXCLUSIVELY. Two transactions each
    // holding S and each waiting to upgrade to X can only be resolved by InnoDB
    // rolling one of them back.
    //
    // Locking X first turns that lock-upgrade deadlock into an ordinary queue:
    // the second sender waits for the first to commit, then proceeds. withRetry
    // below still covers genuine contention, but it no longer has to absorb a
    // self-inflicted one — and it could not always do so, since 8 retries were
    // observed to be exhausted under sustained same-chat load.
    await tx.$queryRaw`SELECT id FROM chats WHERE id = ${chat.id} FOR UPDATE`;

    const message = await tx.message.create({
      data: {
        chatId: chat.id,
        senderId,
        senderRole,
        text: input.text ?? "",
        mediaUrl: input.mediaUrl,
        mediaType: input.mediaType,
        orderId: input.orderId,
        sharedPostId: input.sharedPostId,
        sharedStoryId: input.sharedStoryId,
        // The validated id, NOT input.replyToMessageId — storing the raw value
        // would persist a pointer into someone else's chat even though the
        // quote text above was correctly withheld.
        replyToMessageId: replyToMessageId ?? undefined,
        replyToText: replyToText ?? undefined,
        replyToSenderRole: replyToSenderRole ?? undefined,
        clientKey: input.clientKey,
      },
    });

    // Recipient's unread counter. Always incremented — even when the recipient
    // has this exact thread open, because the thread screen answers every
    // incoming message with a read receipt within one round-trip, which zeroes
    // it again (markReceipts). The old design skipped the increment (and the
    // push) when users.activeChatId matched this chat, but that flag is written
    // by the app on enter/leave, and a killed app, a crash, or a PATCH lost to
    // bad signal left it stuck — after which that chat never badged or
    // notified its user again until they happened to reopen and leave it.
    // Whether someone is looking at a thread is only knowable on their device,
    // so that is where the suppression lives now (notification_service.dart's
    // foreground banner check). The admin side never had it.
    const unreadDelta =
      side === "user" ? { unreadByAdmin: { increment: 1 } } : { unreadByUser: { increment: 1 } };

    const updatedChat = await tx.chat.update({
      where: { id: chat.id },
      data: {
        lastMessageText: preview,
        lastMessageAt: message.createdAt,
        ...unreadDelta,
      },
    });

      return { message, updatedChat };
    }));
  } catch (err) {
    // Concurrent send with the same clientKey lost the UNIQUE race — the
    // winner's row already exists, so return it instead of erroring (the
    // fast-path check above only misses when both requests are truly
    // simultaneous).
    if (
      input.clientKey &&
      err instanceof Prisma.PrismaClientKnownRequestError &&
      err.code === "P2002"
    ) {
      // Scoped to this chat, matching the compound UNIQUE — the winner of the
      // race is by definition a message in the same chat.
      const winner = await prisma.message.findUnique({
        where: { chatId_clientKey: { chatId: chat.id, clientKey: input.clientKey } },
      });
      if (winner) return winner;
    }
    throw err;
  }
  const { message, updatedChat } = txResult;

  publish(`chat:${chat.id}:messages`, { type: "upsert", data: message });
  publishChatEverywhere(updatedChat);

  sendChatPush(chat, side, updatedChat, message, preview).catch(() => {
    /* push is best-effort — never fail the message send over it */
  });

  return message;
}

/** Launcher badge for a customer: unread across every conversation they have,
 * muted ones excluded — a muted chat sends no push, so if it counted the icon
 * number would lag and then jump UP on an unrelated read. Muted = quiet, on
 * the icon too, the way WhatsApp treats it. */
async function unreadBadgeForUser(userId: string): Promise<number> {
  const agg = await prisma.chat.aggregate({
    _sum: { unreadByUser: true },
    where: { userId, mutedByUser: false },
  });
  return agg._sum.unreadByUser ?? 0;
}

/** Launcher badge per admin: unread across every store each of them manages
 * (an admin of two stores sees both backlogs), muted chats excluded as above.
 * Two queries however many admins. */
async function unreadBadgeForAdmins(adminIds: string[]): Promise<Map<string, number>> {
  const result = new Map<string, number>(adminIds.map((id) => [id, 0]));
  if (adminIds.length === 0) return result;
  const memberships = await prisma.storeAdmin.findMany({
    where: { userId: { in: adminIds } },
    select: { userId: true, storeId: true },
  });
  const storeIds = [...new Set(memberships.map((m) => m.storeId))];
  if (storeIds.length === 0) return result;
  const perStore = await prisma.chat.groupBy({
    by: ["storeId"],
    _sum: { unreadByAdmin: true },
    where: { storeId: { in: storeIds }, mutedByAdmin: false },
  });
  const unreadByStore = new Map(perStore.map((r) => [r.storeId, r._sum.unreadByAdmin ?? 0]));
  for (const m of memberships) {
    result.set(m.userId, (result.get(m.userId) ?? 0) + (unreadByStore.get(m.storeId) ?? 0));
  }
  return result;
}

async function sendChatPush(
  chat: Chat,
  side: ChatSide,
  updatedChat: Chat,
  message: Message,
  preview: string
): Promise<void> {
  // `data` is what the app acts on — chatId routes a notification tap into the
  // thread and drives the delivered receipt (notification_service.dart); the
  // rest is display. Muting is honoured here and only here: the unread counter
  // and the realtime fan-out above are unaffected by mute, exactly like a
  // muted WhatsApp chat still counts and still updates, it just stays quiet.
  // No isPushEnabled() gate here, on purpose: a push-less server must still
  // run this through sendPushToUsers so the drop is logged ("push skipped:
  // FCM disabled") — an early return used to leave chat, the highest-volume
  // push, invisible in the log. The lookups it costs are the normal ones.
  const data = {
    type: "chat_message",
    chatId: chat.id,
    messageId: message.id.toString(),
    senderRole: side,
  };
  const opts: PushOptions = {
    channelId: CHAT_PUSH_CHANNEL,
    tag: chat.id,
    wakeApp: true,
  };
  const store = await prisma.store.findUnique({ where: { id: chat.storeId }, select: { name: true } });

  if (side === "user") {
    if (updatedChat.mutedByAdmin) return;
    const admins = await prisma.storeAdmin.findMany({
      where: { storeId: chat.storeId },
      select: { userId: true },
    });
    if (admins.length === 0) return;
    const adminIds = admins.map((a) => a.userId);
    // Titled by who wrote it, the way a messenger does — a store admin reading
    // "<their own store>: hello" could not tell which customer it was from.
    const customer = await prisma.user.findUnique({ where: { id: chat.userId }, select: { name: true } });
    const named = customer?.name || store?.name;
    opts.badgeByUser = await unreadBadgeForAdmins(adminIds);
    // The fallback title is the only part of a chat push the server writes, and
    // the product ships Turkmen/Russian only — so it is taken from each
    // recipient's users.language (lib/copy.ts), never an English literal. The
    // body is the message itself, which needs no translation.
    await sendLocalizedPushToUsers(
      adminIds,
      (copy) => ({ title: named || copy.newMessage, body: preview }),
      data,
      opts
    );
  } else {
    if (updatedChat.mutedByUser) return;
    opts.badgeByUser = new Map([[chat.userId, await unreadBadgeForUser(chat.userId)]]);
    await sendLocalizedPushToUsers(
      [chat.userId],
      (copy) => ({ title: store?.name || copy.newMessage, body: preview }),
      data,
      opts
    );
  }
}

/** After a read receipt: push the corrected launcher badge to the reader's iOS
 * devices (an app-icon number that only ever went up would be worse than none).
 * The admin side corrects every admin of the store, since the counter it
 * cleared is per-store, not per-admin. */
async function syncLauncherBadges(chat: Chat, side: ChatSide): Promise<void> {
  if (!isPushEnabled()) return;
  if (side === "user") {
    await sendBadgeUpdate(new Map([[chat.userId, await unreadBadgeForUser(chat.userId)]]));
    return;
  }
  const admins = await prisma.storeAdmin.findMany({
    where: { storeId: chat.storeId },
    select: { userId: true },
  });
  await sendBadgeUpdate(await unreadBadgeForAdmins(admins.map((a) => a.userId)));
}

/** Newest-first window of what `side` may see. The hide cutoff applies to the
 * first page and to `?before=` paging alike, so scroll-back simply comes up
 * short (or empty) at the cutoff — the client's "short page = no more" rule
 * needs no special case. */
export async function listMessages(
  chat: Chat,
  side: ChatSide,
  opts: { before?: string; limit: number }
): Promise<Message[]> {
  // A malformed cursor means "first page", not a 500 — see lib/ids.ts.
  const before = parseBigIntId(opts.before);
  const rows = await prisma.message.findMany({
    // Two bounds on the same column — the cutoff from below, the cursor from
    // above — hence AND (see visibleWhere).
    where: { AND: [visibleWhere(chat, side), before !== undefined ? { id: { lt: before } } : {}] },
    orderBy: { id: "desc" },
    take: opts.limit,
  });
  return withoutHiddenQuotes(rows, historyCutoff(chat, side));
}

/** Marks every message from the OTHER side as delivered/read. `read` implies
 * `delivered` (a message can't be read before it's delivered). Also clears
 * the caller's own unread counter, matching the "opening a chat clears its
 * badge" behavior the mobile app already had. */
export async function markReceipts(
  chat: Chat,
  side: ChatSide,
  status: "delivered" | "read"
): Promise<void> {
  const now = new Date();
  const counterpartRole: SenderRole = side === "user" ? "admin" : "user";
  // Rows below this side's hide cutoff are not theirs to stamp: the reader
  // cannot see them, so a "Seen" tick on the other side would be a lie. The
  // roll-up below carries the same bound so the other side's client skips
  // exactly the rows the server skipped.
  const cutoff = historyCutoff(chat, side);

  // Count how many rows this receipt actually changes. The message updateMany's
  // `where` already excludes already-read/already-delivered rows, and the chat
  // unread is only touched when it's non-zero — so `changed === 0` means this
  // was a redundant receipt (the client re-syncing an already-read thread).
  const { changed, upToMessageId } = await withRetry(() =>
    prisma.$transaction(async (tx) => {
      const msgs = await tx.message.updateMany({
        where: {
          ...visibleWhere(chat, side),
          senderRole: counterpartRole,
          ...(status === "read" ? { readAt: null } : { deliveredAt: null }),
        },
        data: status === "read" ? { readAt: now, deliveredAt: now } : { deliveredAt: now },
      });
      // The newest row THIS receipt stamped, for the realtime roll-up below.
      // Read back inside the transaction (a transaction always sees its own
      // writes, whatever the isolation level) by the exact timestamp it just
      // wrote, so a message inserted concurrently — which the updateMany did
      // not touch — is never reported as stamped.
      const bound =
        msgs.count === 0
          ? null
          : (
              await tx.message.aggregate({
                _max: { id: true },
                where: {
                  ...visibleWhere(chat, side),
                  senderRole: counterpartRole,
                  ...(status === "read" ? { readAt: now } : { deliveredAt: now }),
                },
              })
            )._max.id;
      // Only 'read' clears the unread badge; 'delivered' leaves it.
      let unreadCleared = 0;
      if (status === "read") {
        const c = await tx.chat.updateMany({
          where:
            side === "user"
              ? { id: chat.id, unreadByUser: { gt: 0 } }
              : { id: chat.id, unreadByAdmin: { gt: 0 } },
          data: side === "user" ? { unreadByUser: 0 } : { unreadByAdmin: 0 },
        });
        unreadCleared = c.count;
      }
      return { changed: msgs.count + unreadCleared, upToMessageId: bound?.toString() ?? null };
    })
  );

  // Nothing changed → skip the re-publish. Publishing unconditionally turned an
  // idempotent receipts call into a fan-out to every subscriber (and, with the
  // old always-POST client, a rebuild storm). At 100K DAU this matters: a read
  // thread must not keep broadcasting snapshots.
  if (changed === 0) return;

  const updatedChat = await prisma.chat.findUniqueOrThrow({ where: { id: chat.id } });
  // A compact roll-up, not a re-snapshot. This used to re-send the whole
  // 200-message window on every receipt; with delivered receipts now firing
  // for each incoming message while the recipient's app is open (see
  // chat_providers.dart), that was up to ~2×200 messages of JSON per message
  // sent, to every subscriber of the thread. The client applies the stamp to
  // every message of `senderRole` that lacks it — the same rows the updateMany
  // above touched.
  //
  // Only when this receipt actually stamped a row. `changed` also counts the
  // unread counter being cleared, and those are not the same event: a read
  // receipt that stamped no message but cleared a non-zero unread (a
  // concurrent sendMessage committing between the two updateMany statements
  // above) would otherwise publish a roll-up whose bound is null — a frame
  // whose only correct interpretation is "ignore me", and which the client
  // read as "no upper bound" and used to stamp the whole window as seen. The
  // unread change still goes out, on the chat document below.
  if (upToMessageId !== null) {
    publish(`chat:${chat.id}:messages`, {
      type: "receipts",
      data: {
        senderRole: counterpartRole,
        status,
        at: now.toISOString(),
        upToMessageId,
        fromMessageId: cutoff?.toString() ?? null,
      },
    });
  }
  publishChatEverywhere(updatedChat);

  if (status === "read") {
    syncLauncherBadges(updatedChat, side).catch(() => {
      /* best-effort, like push itself */
    });
  }
}

export async function setTyping(chat: Chat, side: ChatSide, typing: boolean): Promise<void> {
  const updatedChat = await prisma.chat.update({
    where: { id: chat.id },
    data:
      side === "user"
        ? { typingUserAt: typing ? new Date() : null }
        : { typingAdminAt: typing ? new Date() : null },
  });
  publish(`chat:${chat.id}`, { type: "upsert", data: updatedChat });
}

export async function setMuted(chat: Chat, side: ChatSide, muted: boolean): Promise<void> {
  const updatedChat = await prisma.chat.update({
    where: { id: chat.id },
    data: side === "user" ? { mutedByUser: muted } : { mutedByAdmin: muted },
  });
  publish(`chat:${chat.id}`, { type: "upsert", data: updatedChat });
}

/** Per-side delete: removes the chat from the caller's list AND everything sent
 * so far from their thread; the other participant is untouched. No row is ever
 * deleted — the cutoff written here (hiddenBy*UpToId, see historyCutoff) is
 * what makes them invisible to this side, and the chat returns to their list
 * on the next message (listUserChats/listStoreChats) showing only what arrived
 * after it. Also zeroes this side's unread: a dismissed chat must not keep
 * counting on the tab badge or the launcher icon.
 *
 * Takes the same chats-row X lock sendMessage takes, so a send racing the hide
 * commits wholly before it (id <= cutoff, hidden) or wholly after (id > cutoff,
 * visible — and its createdAt is then also >= hiddenAt, so the timestamp list
 * rule agrees with the id rule). Without the lock MAX(id) could be read while
 * a larger id was still uncommitted, and that message would surface as "new"
 * right after the delete. */
export async function hideChat(chat: Chat, side: ChatSide): Promise<void> {
  const updatedChat = await withRetry(() =>
    prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT id FROM chats WHERE id = ${chat.id} FOR UPDATE`;
      // null on an empty chat: nothing to hide, and NULL already means that.
      const newest = (await tx.message.aggregate({ _max: { id: true }, where: { chatId: chat.id } }))
        ._max.id;
      const now = new Date();
      return tx.chat.update({
        where: { id: chat.id },
        data:
          side === "user"
            ? { hiddenByUserAt: now, hiddenByUserUpToId: newest, unreadByUser: 0 }
            : { hiddenByAdminAt: now, hiddenByAdminUpToId: newest, unreadByAdmin: 0 },
      });
    })
  );

  if (side === "user") {
    publish(`user:${chat.userId}:chats`, { type: "remove", id: chat.id });
  } else {
    publish(`store:${chat.storeId}:chats`, { type: "remove", id: chat.id });
  }
  // The thread channel, never the hider's own list (an upsert there would put
  // back the row just removed): a thread open on the hider's other device
  // reads the new cutoff from this and drops its rows — see chat_providers.dart.
  publish(`chat:${chat.id}`, { type: "upsert", data: updatedChat });

  // The unread just zeroed was on the launcher badge too (iOS shows whatever
  // number the last push carried until told otherwise).
  if ((side === "user" ? chat.unreadByUser : chat.unreadByAdmin) > 0) {
    syncLauncherBadges(updatedChat, side).catch(() => {
      /* best-effort, like push itself */
    });
  }
}
