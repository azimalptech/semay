import { Prisma, type Chat, type Message, type MessageMediaType, type SenderRole } from "@prisma/client";

import { prisma } from "../db.js";
import { parseBigIntId } from "../lib/ids.js";
import type { AccessTokenPayload } from "../lib/jwt.js";
import { publish } from "../realtime/bus.js";
import { withRetry } from "../lib/withRetry.js";
import { sendPushToUsers } from "../notifications/push.js";

export type ChatSide = "user" | "admin";

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

/** Which side of the conversation `auth` is on for `chat` — null if neither
 * (used everywhere a route needs to authorize a chat action). Superadmin
 * counts as the admin side (read/moderate any chat, same as other admin-only
 * surfaces in this codebase). */
function resolveChatSide(chat: Chat, auth: AccessTokenPayload): ChatSide | null {
  if (auth.sub === chat.userId) return "user";
  if (auth.role === "superadmin") return "admin";
  if (auth.role === "admin" && auth.storeIds.includes(chat.storeId)) return "admin";
  return null;
}

export async function getChatForParticipant(
  chatId: string,
  auth: AccessTokenPayload
): Promise<{ chat: Chat; side: ChatSide }> {
  const chat = await prisma.chat.findUnique({ where: { id: chatId } });
  if (!chat) throw new ChatNotFoundError();
  const side = resolveChatSide(chat, auth);
  if (!side) throw new ChatForbiddenError();
  return { chat, side };
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
    // out-of-chat id return nothing, exactly like a deleted one.
    const replyTo = await prisma.message.findFirst({
      where: { id: requestedReplyTo, chatId: chat.id },
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

    // Recipient's unread counter — the user side is skipped if THEY currently
    // have this chat open (activeChatId), matching the old trigger's single-
    // recipient suppression. The admin side has no single "the admin", so it
    // always increments (any one admin having it open doesn't speak for the
    // whole store's admin team). The same activeChatId check also gates the
    // push below — a user looking at the chat shouldn't also get a banner.
    let unreadDelta: { unreadByUser?: { increment: number }; unreadByAdmin?: { increment: number } } = {};
    let userIsViewingChat = false;
    if (side === "user") {
      unreadDelta = { unreadByAdmin: { increment: 1 } };
    } else {
      const recipient = await tx.user.findUnique({
        where: { id: chat.userId },
        select: { activeChatId: true },
      });
      userIsViewingChat = recipient?.activeChatId === chat.id;
      if (!userIsViewingChat) {
        unreadDelta = { unreadByUser: { increment: 1 } };
      }
    }

    const updatedChat = await tx.chat.update({
      where: { id: chat.id },
      data: {
        lastMessageText: preview,
        lastMessageAt: message.createdAt,
        ...unreadDelta,
      },
    });

      return { message, updatedChat, userIsViewingChat };
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
  const { message, updatedChat, userIsViewingChat } = txResult;

  publish(`chat:${chat.id}:messages`, { type: "upsert", data: message });
  publishChatEverywhere(updatedChat);

  sendChatPush(chat, side, updatedChat, preview, userIsViewingChat).catch(() => {
    /* push is best-effort — never fail the message send over it */
  });

  return message;
}

async function sendChatPush(
  chat: Chat,
  side: ChatSide,
  updatedChat: Chat,
  preview: string,
  userIsViewingChat: boolean
): Promise<void> {
  const data = { chatId: chat.id };
  if (side === "user") {
    if (updatedChat.mutedByAdmin) return;
    const admins = await prisma.storeAdmin.findMany({
      where: { storeId: chat.storeId },
      select: { userId: true },
    });
    if (admins.length === 0) return;
    const store = await prisma.store.findUnique({ where: { id: chat.storeId }, select: { name: true } });
    await sendPushToUsers(admins.map((a) => a.userId), store?.name ?? "New message", preview, data);
  } else {
    if (updatedChat.mutedByUser || userIsViewingChat) return;
    const store = await prisma.store.findUnique({ where: { id: chat.storeId }, select: { name: true } });
    await sendPushToUsers([chat.userId], store?.name ?? "New message", preview, data);
  }
}

export async function listMessages(
  chatId: string,
  opts: { before?: string; limit: number }
): Promise<Message[]> {
  // A malformed cursor means "first page", not a 500 — see lib/ids.ts.
  const before = parseBigIntId(opts.before);
  return prisma.message.findMany({
    where: {
      chatId,
      ...(before !== undefined ? { id: { lt: before } } : {}),
    },
    orderBy: { id: "desc" },
    take: opts.limit,
  });
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

  // Count how many rows this receipt actually changes. The message updateMany's
  // `where` already excludes already-read/already-delivered rows, and the chat
  // unread is only touched when it's non-zero — so `changed === 0` means this
  // was a redundant receipt (the client re-syncing an already-read thread).
  const changed = await withRetry(() =>
    prisma.$transaction(async (tx) => {
      const msgs = await tx.message.updateMany({
        where: {
          chatId: chat.id,
          senderRole: counterpartRole,
          ...(status === "read" ? { readAt: null } : { deliveredAt: null }),
        },
        data: status === "read" ? { readAt: now, deliveredAt: now } : { deliveredAt: now },
      });
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
      return msgs.count + unreadCleared;
    })
  );

  // Nothing changed → skip the re-publish. Publishing unconditionally turned an
  // idempotent receipts call into a fan-out to every subscriber (and, with the
  // old always-POST client, a rebuild storm). At 100K DAU this matters: a read
  // thread must not keep broadcasting snapshots.
  if (changed === 0) return;

  const updatedChat = await prisma.chat.findUniqueOrThrow({ where: { id: chat.id } });
  publish(`chat:${chat.id}:messages`, { type: "snapshot", data: await listMessages(chat.id, { limit: 200 }) });
  publishChatEverywhere(updatedChat);
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

/** Soft-hide for the caller's side only — the other participant still sees
 * it. Reappears automatically on the recipient's next message (see
 * listUserChats/listStoreChats). */
export async function hideChat(chat: Chat, side: ChatSide): Promise<void> {
  const updatedChat = await prisma.chat.update({
    where: { id: chat.id },
    data: side === "user" ? { hiddenByUserAt: new Date() } : { hiddenByAdminAt: new Date() },
  });
  if (side === "user") {
    publish(`user:${chat.userId}:chats`, { type: "remove", id: chat.id });
  } else {
    publish(`store:${chat.storeId}:chats`, { type: "remove", id: chat.id });
  }
  void updatedChat;
}
