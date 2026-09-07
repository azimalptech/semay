import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { createOrGetChat, sendMessage } from "../src/chats/service.js";
import { prisma } from "../src/db.js";
import { subscribe, type RealtimeEvent } from "../src/realtime/bus.js";
import { setStoreAdmin } from "../src/stores/service.js";
import {
  authHeader,
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  refreshedToken,
  type App,
} from "./helpers.js";

// DELETE /chats/:id used to be a list-only hide: the deleting side's thread,
// socket snapshot and ?before= paging still returned every old message, and
// the moment the other side wrote again the whole history was back in that
// side's list. Owner decision: after deleting, that side only ever sees
// messages newer than the deletion — cut by message id (chats.hiddenBy*UpToId)
// — while the other side is unaffected. These are the contracts the mobile
// thread (chat_providers.dart) relies on to never resurrect old rows.
describe("chat-delete: a per-side hide also hides that side's history", () => {
  let app: App;
  let adminId: string;
  let adminToken: string;
  let superadminId: string;
  let superadminToken: string;
  let storeId: string;
  const userIds: string[] = [];

  beforeAll(async () => {
    app = await buildApp();
    const admin = await createUserWithToken("user");
    adminId = admin.userId;
    const store = await createStore("Hide History Store", adminId);
    storeId = store.id;
    await setStoreAdmin(storeId, adminId, true);
    adminToken = await refreshedToken(adminId);
    const sa = await createUserWithToken("superadmin");
    superadminId = sa.userId;
    superadminToken = sa.token;
  });

  afterAll(async () => {
    await cleanupStores([storeId]); // cascades every chat and message below
    await cleanupUsers([adminId, superadminId, ...userIds]);
    await app.close();
  });

  // The chat id is deterministic per user+store, so a fresh customer is the
  // only way to get a fresh, empty thread per case.
  async function freshChat() {
    const user = await createUserWithToken("user");
    userIds.push(user.userId);
    const chat = await createOrGetChat(user.userId, storeId);
    return { chat, userToken: user.token };
  }

  const del = (chatId: string, token: string) =>
    app.inject({ method: "DELETE", url: `/api/v1/chats/${chatId}`, headers: authHeader(token) });
  type Quoted = {
    id: string;
    text: string;
    replyToMessageId: string | null;
    replyToText: string | null;
    replyToSenderRole: string | null;
  };
  const messageRows = async (chatId: string, token: string, query = ""): Promise<Quoted[]> => {
    const res = await app.inject({
      method: "GET",
      url: `/api/v1/chats/${chatId}/messages${query}`,
      headers: authHeader(token),
    });
    expect(res.statusCode).toBe(200);
    return res.json().messages as Quoted[];
  };
  const messages = async (chatId: string, token: string, query = ""): Promise<string[]> =>
    (await messageRows(chatId, token, query)).map((m) => m.id);
  const listedChatIds = async (token: string, query = ""): Promise<string[]> => {
    const res = await app.inject({ method: "GET", url: `/api/v1/chats${query}`, headers: authHeader(token) });
    expect(res.statusCode).toBe(200);
    return (res.json().chats as { id: string }[]).map((c) => c.id);
  };
  const row = (chatId: string) => prisma.chat.findUniqueOrThrow({ where: { id: chatId } });
  const str = (...ids: bigint[]) => ids.map((id) => id.toString());
  // The list-return rule is still `lastMessageAt > hiddenAt` (owner decision:
  // timestamps stay). A message sent in the same millisecond as the hide would
  // tie and stay off the list until the next one — a documented edge, not
  // what these cases are about, so the post-hide send waits a tick.
  const tick = () => new Promise((r) => setTimeout(r, 5));

  it("customer deletes: cutoff = newest id, unread zeroed, thread and list empty until the store writes again", async () => {
    const { chat, userToken } = await freshChat();
    const oldA = await sendMessage(chat, "user", chat.userId, { text: "old-A" });
    const oldB = await sendMessage(chat, "admin", adminId, { text: "old-B" });
    const oldC = await sendMessage(chat, "admin", adminId, { text: "old-C" });

    const res = await del(chat.id, userToken);
    expect(res.statusCode).toBe(200);

    const hidden = await row(chat.id);
    expect(hidden.hiddenByUserUpToId).toBe(oldC.id);
    expect(hidden.hiddenByUserAt).not.toBeNull();
    expect(hidden.unreadByUser).toBe(0);
    // The store's side is untouched — including its unread for old-A.
    expect(hidden.hiddenByAdminUpToId).toBeNull();
    expect(hidden.hiddenByAdminAt).toBeNull();
    expect(hidden.unreadByAdmin).toBe(1);

    expect(await messages(chat.id, userToken)).toEqual([]);
    expect(await listedChatIds(userToken)).not.toContain(chat.id);

    await tick();
    const fresh = await sendMessage(hidden, "admin", adminId, { text: "new-after-hide" });

    // Back in the list, and the thread holds exactly the new message: first
    // page, a deliberately small page, and paging below it all stop there.
    expect(await listedChatIds(userToken)).toContain(chat.id);
    expect(await messages(chat.id, userToken)).toEqual(str(fresh.id));
    expect(await messages(chat.id, userToken, "?limit=1")).toEqual(str(fresh.id));
    expect(await messages(chat.id, userToken, `?before=${fresh.id}`)).toEqual([]);

    expect(await messages(chat.id, adminToken)).toEqual(str(fresh.id, oldC.id, oldB.id, oldA.id));
  });

  it("store deletes: symmetric — the store sees only the customer's next message, the customer everything", async () => {
    const { chat, userToken } = await freshChat();
    const oldA = await sendMessage(chat, "user", chat.userId, { text: "old-A" });
    const oldB = await sendMessage(chat, "user", chat.userId, { text: "old-B" });

    expect((await del(chat.id, adminToken)).statusCode).toBe(200);

    const hidden = await row(chat.id);
    expect(hidden.hiddenByAdminUpToId).toBe(oldB.id);
    expect(hidden.unreadByAdmin).toBe(0);
    expect(hidden.hiddenByUserUpToId).toBeNull();
    expect(await messages(chat.id, adminToken)).toEqual([]);
    expect(await listedChatIds(adminToken, `?storeId=${storeId}`)).not.toContain(chat.id);

    await tick();
    const fresh = await sendMessage(hidden, "user", chat.userId, { text: "new-after-hide" });

    expect(await listedChatIds(adminToken, `?storeId=${storeId}`)).toContain(chat.id);
    expect(await messages(chat.id, adminToken)).toEqual(str(fresh.id));
    expect(await messages(chat.id, adminToken, `?before=${fresh.id}`)).toEqual([]);
    expect(await messages(chat.id, userToken)).toEqual(str(fresh.id, oldB.id, oldA.id));
  });

  it("each side keeps its own suffix when both delete at different points", async () => {
    const { chat, userToken } = await freshChat();
    await sendMessage(chat, "user", chat.userId, { text: "m1" });
    await sendMessage(chat, "admin", adminId, { text: "m2" });
    expect((await del(chat.id, userToken)).statusCode).toBe(200);
    const m3 = await sendMessage(chat, "admin", adminId, { text: "m3" });
    const m4 = await sendMessage(chat, "user", chat.userId, { text: "m4" });
    expect((await del(chat.id, adminToken)).statusCode).toBe(200);
    const m5 = await sendMessage(chat, "user", chat.userId, { text: "m5" });

    expect(await messages(chat.id, userToken)).toEqual(str(m5.id, m4.id, m3.id));
    expect(await messages(chat.id, adminToken)).toEqual(str(m5.id));
  });

  it("a read receipt after the chat returns stamps only rows above the cutoff, and the roll-up carries the bound", async () => {
    const { chat, userToken } = await freshChat();
    const oldA = await sendMessage(chat, "admin", adminId, { text: "old-A" });
    expect((await del(chat.id, userToken)).statusCode).toBe(200);
    const fresh = await sendMessage(await row(chat.id), "admin", adminId, { text: "fresh" });

    // In-process bus subscription: with REDIS_URL set the event round-trips
    // through Redis, so it is awaited rather than assumed to be synchronous.
    const events: RealtimeEvent[] = [];
    const unsub = await subscribe(`chat:${chat.id}:messages`, (e) => events.push(e));
    try {
      const res = await app.inject({
        method: "POST",
        url: `/api/v1/chats/${chat.id}/receipts`,
        headers: authHeader(userToken),
        payload: { status: "read" },
      });
      expect(res.statusCode).toBe(200);
      const deadline = Date.now() + 5000;
      while (!events.some((e) => e.type === "receipts") && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 20));
      }
    } finally {
      unsub();
    }

    expect((await prisma.message.findUniqueOrThrow({ where: { id: oldA.id } })).readAt).toBeNull();
    expect((await prisma.message.findUniqueOrThrow({ where: { id: fresh.id } })).readAt).not.toBeNull();
    const receipt = events.find((e) => e.type === "receipts");
    expect(receipt?.type).toBe("receipts");
    expect(receipt?.type === "receipts" && receipt.data).toMatchObject({
      senderRole: "admin",
      status: "read",
      upToMessageId: fresh.id.toString(),
      fromMessageId: oldA.id.toString(),
    });
  });

  it("a reply quoting a message below the sender's own cutoff sends without the quote", async () => {
    const { chat, userToken } = await freshChat();
    const old = await sendMessage(chat, "admin", adminId, { text: "quote me" });
    expect((await del(chat.id, userToken)).statusCode).toBe(200);
    // A visible row above the cutoff must exist here: the first version of
    // the lookup spread the cutoff filter over the quoted id and so returned
    // "any visible message" — which only an otherwise-empty thread hid.
    await sendMessage(await row(chat.id), "admin", adminId, { text: "visible, but not the one quoted" });

    const res = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chat.id}/messages`,
      headers: authHeader(userToken),
      payload: { text: "reply", replyToMessageId: old.id.toString() },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().message.replyToMessageId).toBeNull();
    expect(res.json().message.replyToText).toBeNull();
    expect(res.json().message.replyToSenderRole).toBeNull();

    // The store never deleted, so for it the same message is still quotable.
    const adminReply = await sendMessage(await row(chat.id), "admin", adminId, {
      text: "still here",
      replyToMessageId: old.id.toString(),
    });
    expect(adminReply.replyToMessageId).toBe(old.id);
    expect(adminReply.replyToText).toBe("quote me");
  });

  it("the other side quoting a row below my cutoff: I get the reply without the quote, they keep it", async () => {
    // Review finding: the cutoff bounded the sender's OWN quote lookup, but a
    // reply from the side that never deleted carries the quoted row's text
    // inline (replyToText) on a message that is itself visible — the hidden
    // history, served back verbatim to the side that deleted it.
    const { chat, userToken } = await freshChat();
    const secret = await sendMessage(chat, "admin", adminId, { text: "SECRET-OLD-TEXT" });
    expect((await del(chat.id, userToken)).statusCode).toBe(200);
    const reply = await sendMessage(await row(chat.id), "admin", adminId, {
      text: "look above",
      replyToMessageId: secret.id.toString(),
    });
    // Stored with the quote — the store never deleted, so for it the original
    // is still there to point at.
    expect(reply.replyToText).toBe("SECRET-OLD-TEXT");

    expect(await messageRows(chat.id, userToken)).toEqual([
      expect.objectContaining({
        id: reply.id.toString(),
        text: "look above",
        replyToMessageId: null,
        replyToText: null,
        replyToSenderRole: null,
      }),
    ]);
    expect((await messageRows(chat.id, adminToken)).find((m) => m.id === reply.id.toString())).toMatchObject({
      replyToMessageId: secret.id.toString(),
      replyToText: "SECRET-OLD-TEXT",
      replyToSenderRole: "admin",
    });

    // The mask is by quoted id, not blanket: a quote of a row above my cutoff
    // is mine to see, in the first page and through ?before= paging alike.
    const mine = await sendMessage(await row(chat.id), "user", chat.userId, { text: "mine" });
    const quotesMine = await sendMessage(await row(chat.id), "admin", adminId, {
      text: "re: mine",
      replyToMessageId: mine.id.toString(),
    });
    const quoted = { replyToMessageId: mine.id.toString(), replyToText: "mine", replyToSenderRole: "user" };
    expect((await messageRows(chat.id, userToken)).find((m) => m.id === quotesMine.id.toString())).toMatchObject(quoted);
    const later = await sendMessage(await row(chat.id), "user", chat.userId, { text: "after" });
    expect(await messageRows(chat.id, userToken, `?before=${later.id}&limit=1`)).toEqual([
      expect.objectContaining({ id: quotesMine.id.toString(), ...quoted }),
    ]);
  });

  it("superadmin reads as the store's side: bounded by the store's delete, not by the customer's", async () => {
    // resolveChatSide puts superadmin on the admin side everywhere — the
    // store:{id}:chats list, DELETE (owner decision: superadmin delete keeps
    // the per-store-admin semantics) — so the thread follows the same rule
    // rather than being the one unfiltered read. Pinned here so a change of
    // mind is a deliberate edit, not a drift.
    const { chat, userToken } = await freshChat();
    const old = await sendMessage(chat, "user", chat.userId, { text: "old" });
    expect((await del(chat.id, userToken)).statusCode).toBe(200);
    expect(await messages(chat.id, superadminToken)).toEqual(str(old.id));

    expect((await del(chat.id, adminToken)).statusCode).toBe(200);
    expect(await messages(chat.id, superadminToken)).toEqual([]);
    await tick();
    const fresh = await sendMessage(await row(chat.id), "user", chat.userId, { text: "fresh" });
    expect(await messages(chat.id, superadminToken)).toEqual(str(fresh.id));
    expect(await messages(chat.id, userToken)).toEqual(str(fresh.id));
  });

  it("deleting an empty chat records no cutoff and hides nothing that arrives later", async () => {
    const { chat, userToken } = await freshChat();
    expect((await del(chat.id, userToken)).statusCode).toBe(200);

    const hidden = await row(chat.id);
    expect(hidden.hiddenByUserUpToId).toBeNull();
    expect(hidden.hiddenByUserAt).not.toBeNull();

    const first = await sendMessage(hidden, "admin", adminId, { text: "first ever" });
    expect(await messages(chat.id, userToken)).toEqual(str(first.id));
  });

  it("a delete racing 20 sends leaves every message wholly before or wholly after the cutoff", async () => {
    // hideChat takes the same chats-row X lock sendMessage does, so MAX(id)
    // can never be read while a larger id is still uncommitted. Every message
    // must land on one side of the cutoff, and every visible one must also
    // satisfy the timestamp list rule (createdAt >= hiddenAt) — otherwise the
    // thread would show a message the list still hides.
    const { chat, userToken } = await freshChat();
    await sendMessage(chat, "admin", adminId, { text: "seed" });

    const N = 20;
    const [hide] = await Promise.all([
      del(chat.id, userToken),
      ...Array.from({ length: N }, (_v, i) => sendMessage(chat, "admin", adminId, { text: `race ${i}` })),
    ]);
    expect(hide.statusCode).toBe(200);

    const hidden = await row(chat.id);
    const cutoff = hidden.hiddenByUserUpToId;
    const hiddenAt = hidden.hiddenByUserAt;
    expect(cutoff).not.toBeNull();
    expect(hiddenAt).not.toBeNull();

    const all = await prisma.message.findMany({ where: { chatId: chat.id }, orderBy: { id: "asc" } });
    expect(all).toHaveLength(N + 1);
    expect(all.some((m) => m.id === cutoff)).toBe(true); // the cutoff is a real row
    for (const m of all) {
      if (m.id > cutoff!) expect(m.createdAt.getTime()).toBeGreaterThanOrEqual(hiddenAt!.getTime());
    }

    const expected = all.filter((m) => m.id > cutoff!).map((m) => m.id.toString()).reverse();
    expect(await messages(chat.id, userToken, "?limit=200")).toEqual(expected);
    expect(await messages(chat.id, adminToken, "?limit=200")).toHaveLength(N + 1);
  });
});
