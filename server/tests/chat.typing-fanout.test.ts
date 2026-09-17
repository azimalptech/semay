import { afterAll, beforeAll, expect, it } from "vitest";

import { createOrGetChat, setTyping } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { closeBus, subscribe, type RealtimeEvent } from "../src/realtime/bus.js";
import { cleanupStores, cleanupUsers, createStore, createUserWithToken } from "./helpers.js";

// "Typing…" under their name in the INBOX (chat_list_screen.dart) needs the
// chat row to reach the chat-LIST channels when the stamp changes. It never
// did: setTyping published to `chat:{id}` only, so the field the list reads
// was only refreshed when some unrelated event happened to republish the row —
// which is why the inbox could never show typing at all. It now fans out like
// every other chat change (publishChatEverywhere).
//
// The thread channel must keep getting it too: that is what the open
// conversation's three-dot bubble is driven by.

let userId: string;
let ownerId: string;
let storeId: string;
let chatId: string;

beforeAll(async () => {
  const owner = await createUserWithToken("admin");
  const customer = await createUserWithToken("user");
  ownerId = owner.userId;
  userId = customer.userId;
  const store = await createStore("__TYPING_FANOUT__", ownerId);
  storeId = store.id;
  const chat = await createOrGetChat(userId, storeId);
  chatId = chat.id;
});

afterAll(async () => {
  await prisma.chat.deleteMany({ where: { storeId } });
  await cleanupStores([storeId]);
  await cleanupUsers([userId, ownerId]);
  await closeBus();
});

it("a typing heartbeat reaches the thread AND both chat-list channels", async () => {
  const seen: Array<{ channel: string; event: RealtimeEvent }> = [];
  const record = (channel: string) => (event: RealtimeEvent) => seen.push({ channel, event });
  const offs = await Promise.all([
    subscribe(`chat:${chatId}`, record(`chat:${chatId}`)),
    subscribe(`user:${userId}:chats`, record(`user:${userId}:chats`)),
    subscribe(`store:${storeId}:chats`, record(`store:${storeId}:chats`)),
  ]);

  try {
    const chat = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    await setTyping(chat, "admin", true);

    expect(seen.map((s) => s.channel).sort()).toEqual(
      [`chat:${chatId}`, `store:${storeId}:chats`, `user:${userId}:chats`].sort()
    );
    for (const { event } of seen) {
      expect(event.type).toBe("upsert");
      const row = (event as { data: Record<string, unknown> }).data;
      // The stamp the app reads, on the row the list already renders.
      expect(row.id).toBe(chatId);
      expect(row.typingAdminAt).not.toBeNull();
      expect(row.typingUserAt).toBeNull();
    }

    // Stopping is published the same way, or the inbox would be left saying
    // "typing…" until the freshness window ran out on its own.
    seen.length = 0;
    const typingChat = await prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
    await setTyping(typingChat, "admin", false);
    expect(seen).toHaveLength(3);
    for (const { event } of seen) {
      expect((event as { data: Record<string, unknown> }).data.typingAdminAt).toBeNull();
    }
  } finally {
    for (const off of offs) off();
  }
});
