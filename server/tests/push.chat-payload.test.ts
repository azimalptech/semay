import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { sendPushToUsers } from "../src/notifications/push.js";
import {
  authHeader,
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  refreshedToken,
  TEST_FIXTURE_NAME,
  type App,
} from "./helpers.js";

// Chat pushes name the chat channel and the phone's default sound;
// nothing else does. Pinned at the firebaseAdmin seam (the way
// notifications.broadcast.test.ts keeps announcements on `announcements` with
// sound "default") for BOTH directions, because the two sides build their push
// separately in chats/service.ts sendChatPush. The last case is the guard for
// everything else: a sendPushToUsers with no options is exactly what it always
// was — default sound, no channel — so no other notice can inherit the message
// sound by accident (orders/service.ts names its own channel on top of that).
const fcm = vi.hoisted(() => ({ sendEachForMulticast: vi.fn() }));

vi.mock("../src/lib/firebaseAdmin.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/firebaseAdmin.js")>();
  return {
    ...actual,
    getFcmMessaging: () => ({ sendEachForMulticast: fcm.sendEachForMulticast }),
    getFcmDisabledReason: () => undefined,
  };
});

interface MulticastCall {
  tokens: string[];
  android?: { notification?: Record<string, unknown> };
  apns?: { payload?: { aps?: Record<string, unknown> } };
}

function callsTo(token: string): MulticastCall[] {
  return fcm.sendEachForMulticast.mock.calls
    .map((c) => c[0] as MulticastCall)
    .filter((m) => m.tokens.includes(token));
}

describe("chat push payload: channel and sound", () => {
  let app: App;
  let userId: string;
  let userToken: string;
  let adminId: string;
  let adminToken: string;
  let superadminId: string;
  let storeId: string;
  let chatId: string;
  const adminFcm = `test-payload-admin-${Math.random().toString(36).slice(2)}`;
  const userFcm = `test-payload-user-${Math.random().toString(36).slice(2)}`;
  const superadminFcm = `test-payload-super-${Math.random().toString(36).slice(2)}`;

  beforeAll(async () => {
    app = await buildApp();
    fcm.sendEachForMulticast.mockImplementation(async (msg: { tokens: string[] }) => ({
      successCount: msg.tokens.length,
      failureCount: 0,
      responses: msg.tokens.map(() => ({ success: true })),
    }));
    const user = await createUserWithToken("user");
    userId = user.userId;
    userToken = user.token;
    const admin = await createUserWithToken("admin");
    adminId = admin.userId;
    const store = await createStore(`${TEST_FIXTURE_NAME} push payload`, adminId);
    storeId = store.id;
    await prisma.storeAdmin.create({ data: { storeId, userId: adminId } });
    adminToken = await refreshedToken(adminId); // storeIds live in the token
    superadminId = (await createUserWithToken("superadmin")).userId;
    await prisma.userFcmToken.create({ data: { userId: adminId, token: adminFcm, platform: "ios" } });
    await prisma.userFcmToken.create({ data: { userId, token: userFcm, platform: "android" } });
    await prisma.userFcmToken.create({
      data: { userId: superadminId, token: superadminFcm, platform: "android" },
    });
    const created = await app.inject({
      method: "POST",
      url: "/api/v1/chats",
      headers: authHeader(userToken),
      payload: { storeId },
    });
    expect(created.statusCode).toBe(201);
    chatId = created.json().chat.id as string;
  });

  afterAll(async () => {
    await cleanupStores([storeId]); // cascades the chat, its messages, the order and the admin row
    await cleanupUsers([userId, adminId, superadminId]);
    await app.close();
  });

  it("customer → admin and admin → customer both name chat_messages and the DEFAULT sound", async () => {
    const sent = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/messages`,
      headers: authHeader(userToken),
      payload: { text: "hello from customer" },
    });
    expect(sent.statusCode).toBe(201);
    // The push runs after the send returns (best-effort, detached from it).
    await vi.waitFor(() => expect(callsTo(adminFcm)).not.toHaveLength(0));

    const reply = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/messages`,
      headers: authHeader(adminToken),
      payload: { text: "hello from store" },
    });
    expect(reply.statusCode).toBe(201);
    await vi.waitFor(() => expect(callsTo(userFcm)).not.toHaveLength(0));

    for (const token of [adminFcm, userFcm]) {
      const m = callsTo(token).at(-1)!;
      // The phone's own notification sound, exactly like an order notice: the
      // bundled chat sound was removed at the owner's request, and with it
      // the reason "chat_messages" ever had to be re-minted as a _v2 id.
      expect(m.android?.notification).toMatchObject({
        channelId: "chat_messages",
        sound: "default",
        tag: chatId,
      });
      expect(m.apns?.payload?.aps).toMatchObject({
        sound: "default",
        contentAvailable: true,
        threadId: chatId,
      });
    }
  });

  it("an order notice names the orders channel and keeps the default sound", async () => {
    fcm.sendEachForMulticast.mockClear();
    const accepted = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/orders`,
      headers: authHeader(adminToken),
      payload: { itemQuantity: 2 },
    });
    expect(accepted.statusCode).toBe(201);
    const m = callsTo(superadminFcm).at(-1);
    expect(m).toBeDefined();
    expect(m!.android?.notification).toMatchObject({ channelId: "orders", sound: "default" });
    expect(m!.android?.notification).not.toHaveProperty("tag");
    expect(m!.apns?.payload?.aps).toMatchObject({ sound: "default" });
  });

  it("a push with no options keeps the default sound and names no channel", async () => {
    fcm.sendEachForMulticast.mockClear();
    await sendPushToUsers([userId], "New order", "someone placed an order (1)");
    const m = callsTo(userFcm).at(-1);
    expect(m).toBeDefined();
    expect(m!.android?.notification).toMatchObject({ sound: "default" });
    expect(m!.android?.notification).not.toHaveProperty("channelId");
    expect(m!.apns?.payload?.aps).toMatchObject({ sound: "default" });
  });
});
