import type { Message, Role } from "@prisma/client";

import { listMessages, listStoreChats, listUserChats, resolveChatSide } from "../chats/service.js";
import { prisma } from "../db.js";

export interface ChannelAuthCtx {
  userId: string;
  role: Role;
  storeIds: string[];
}

export interface ChannelHandler {
  pattern: RegExp;
  /** Public channels (post counts) return true unconditionally; private ones
   * (chats) check DB-derived participancy — never trust the WS connection's
   * cached claims alone for this, since storeIds can go stale for up to the
   * access token's TTL. */
  authorize: (ctx: ChannelAuthCtx, match: RegExpMatchArray) => Promise<boolean>;
  /** `ctx` is the identity `authorize` just accepted. A private channel's
   * snapshot is shaped for that subscriber — a chat's messages stop at their
   * side's hide cutoff — so it is derived from the same ctx, not re-guessed. */
  snapshot: (match: RegExpMatchArray, ctx: ChannelAuthCtx) => Promise<unknown>;
}

const POST_COUNTS_SELECT = {
  id: true,
  likesCount: true,
  savesCount: true,
  viewsCount: true,
  sentCount: true,
  sharesCount: true,
} as const;

async function isChatParticipant(ctx: ChannelAuthCtx, chatId: string): Promise<boolean> {
  const chat = await prisma.chat.findUnique({
    where: { id: chatId },
    select: { userId: true, storeId: true },
  });
  return chat !== null && resolveChatSide(chat, ctx) !== null;
}

/** The subscriber's view of the thread — what GET /chats/:id/messages would
 * return them — never the raw table: the side that deleted the chat must not
 * get its old history back through the socket. */
async function chatMessagesSnapshot(chatId: string, ctx: ChannelAuthCtx): Promise<Message[]> {
  const chat = await prisma.chat.findUnique({ where: { id: chatId } });
  // authorize passed for this ctx a moment ago; null here means the chat was
  // cascade-deleted in between, and there is nothing left to show.
  const side = chat && resolveChatSide(chat, ctx);
  if (!chat || !side) return [];
  return listMessages(chat, side, { limit: 200 });
}

// Ordered by specificity — "chat:{id}:messages" must be tested before the
// bare "chat:{id}" pattern would otherwise also match its prefix.
const channelHandlers: ChannelHandler[] = [
  {
    pattern: /^post:([\w-]+)$/,
    authorize: async () => true, // public read, matches the old rules
    snapshot: (m) => prisma.post.findUnique({ where: { id: m[1] }, select: POST_COUNTS_SELECT }),
  },
  {
    pattern: /^chat:([\w-]+):messages$/,
    authorize: (ctx, m) => isChatParticipant(ctx, m[1]!),
    snapshot: (m, ctx) => chatMessagesSnapshot(m[1]!, ctx),
  },
  {
    pattern: /^chat:([\w-]+)$/,
    authorize: (ctx, m) => isChatParticipant(ctx, m[1]!),
    snapshot: (m) => prisma.chat.findUnique({ where: { id: m[1] } }),
  },
  {
    pattern: /^user:([\w-]+):chats$/,
    authorize: async (ctx, m) => ctx.userId === m[1] || ctx.role === "superadmin",
    snapshot: (m) => listUserChats(m[1]!),
  },
  {
    pattern: /^store:([\w-]+):chats$/,
    authorize: async (ctx, m) =>
      ctx.role === "superadmin" || (ctx.role === "admin" && ctx.storeIds.includes(m[1]!)),
    snapshot: (m) => listStoreChats(m[1]!),
  },
];

export function findChannelHandler(channel: string): { handler: ChannelHandler; match: RegExpMatchArray } | null {
  for (const handler of channelHandlers) {
    const match = channel.match(handler.pattern);
    if (match) return { handler, match };
  }
  return null;
}
