import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { COPY } from "../src/lib/copy.js";
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

// SeMay ships Turkmen and Russian only — deliberately no English anywhere a
// person can read (mobile/lib/core/l10n.dart, res/values + res/values-ru for
// the Android channel names). Every string the SERVER writes into a
// notification used to be an English literal ("New message", "New order",
// "<name> placed an order (n)", "Order accepted ✅"), which is the one place
// that rule was not being kept. They now come from src/lib/copy.ts, picked by
// the recipient's users.language, and this pins that: the seam is the same
// firebaseAdmin mock push.chat-payload.test.ts uses, so what is asserted is
// the payload FCM would actually have been handed.
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
  notification?: { title?: string; body?: string };
}

function lastTo(token: string): MulticastCall["notification"] {
  const calls = fcm.sendEachForMulticast.mock.calls
    .map((c) => c[0] as MulticastCall)
    .filter((m) => m.tokens.includes(token));
  return calls.at(-1)?.notification;
}

describe("push copy is written in the recipient's language, never English", () => {
  let app: App;
  let userId: string;
  let userToken: string;
  let adminId: string;
  let adminToken: string;
  let tkSuperId: string;
  let ruSuperId: string;
  let storeId: string;
  let chatId: string;
  const rnd = Math.random().toString(36).slice(2);
  const userFcm = `test-l10n-user-${rnd}`;
  const adminFcm = `test-l10n-admin-${rnd}`;
  const tkSuperFcm = `test-l10n-super-tk-${rnd}`;
  const ruSuperFcm = `test-l10n-super-ru-${rnd}`;

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
    // The fallback title only shows when neither the sender's name nor the
    // store's is set, so the fixture deliberately has neither.
    const store = await createStore("", adminId);
    storeId = store.id;
    await prisma.storeAdmin.create({ data: { storeId, userId: adminId } });
    adminToken = await refreshedToken(adminId);
    await prisma.user.update({ where: { id: userId }, data: { name: "", language: "tk" } });
    await prisma.user.update({ where: { id: adminId }, data: { name: "", language: "ru" } });

    tkSuperId = (await createUserWithToken("superadmin")).userId;
    ruSuperId = (await createUserWithToken("superadmin")).userId;
    await prisma.user.update({ where: { id: tkSuperId }, data: { language: "tk" } });
    await prisma.user.update({ where: { id: ruSuperId }, data: { language: "ru" } });

    for (const [id, token] of [
      [userId, userFcm],
      [adminId, adminFcm],
      [tkSuperId, tkSuperFcm],
      [ruSuperId, ruSuperFcm],
    ] as const) {
      await prisma.userFcmToken.create({ data: { userId: id, token, platform: "android" } });
    }

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
    await cleanupStores([storeId]); // cascades the chat, its messages and the order
    await cleanupUsers([userId, adminId, tkSuperId, ruSuperId]);
    await app.close();
  });

  it("splits one chat push into a Turkmen and a Russian one, by users.language", async () => {
    fcm.sendEachForMulticast.mockClear();
    // Admin → customer: the customer is tk, so the nameless store falls back to
    // the Turkmen title.
    const reply = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/messages`,
      headers: authHeader(adminToken),
      payload: { text: "salam" },
    });
    expect(reply.statusCode).toBe(201);
    await vi.waitFor(() => expect(lastTo(userFcm)).toBeDefined());
    expect(lastTo(userFcm)).toEqual({ title: COPY.tk.newMessage, body: "salam" });

    // Customer → admin: the same nameless chat, but this recipient is ru.
    const sent = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/messages`,
      headers: authHeader(userToken),
      payload: { text: "privet" },
    });
    expect(sent.statusCode).toBe(201);
    await vi.waitFor(() => expect(lastTo(adminFcm)).toBeDefined());
    expect(lastTo(adminFcm)).toEqual({ title: COPY.ru.newMessage, body: "privet" });

    // The old literal is gone from both sides.
    for (const token of [userFcm, adminFcm]) {
      expect(lastTo(token)?.title).not.toBe("New message");
    }

    // And the customer's language wins when they switch it.
    await prisma.user.update({ where: { id: userId }, data: { language: "ru" } });
    const again = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/messages`,
      headers: authHeader(adminToken),
      payload: { text: "ещё" },
    });
    expect(again.statusCode).toBe(201);
    await vi.waitFor(() => expect(lastTo(userFcm)?.title).toBe(COPY.ru.newMessage));
    await prisma.user.update({ where: { id: userId }, data: { language: "tk" } });
  });

  it("gives each superadmin the order notice in their own language", async () => {
    fcm.sendEachForMulticast.mockClear();
    const accepted = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/orders`,
      headers: authHeader(adminToken),
      payload: { itemQuantity: 2 },
    });
    expect(accepted.statusCode).toBe(201);

    await vi.waitFor(() => {
      expect(lastTo(tkSuperFcm)).toBeDefined();
      expect(lastTo(ruSuperFcm)).toBeDefined();
    });
    // The customer has no name in this fixture, so the body names their phone.
    const customer = await prisma.user.findUniqueOrThrow({
      where: { id: userId },
      select: { phone: true },
    });
    expect(lastTo(tkSuperFcm)).toEqual({
      title: COPY.tk.newOrder,
      body: COPY.tk.orderPlaced(customer.phone, 2),
    });
    expect(lastTo(ruSuperFcm)).toEqual({
      title: COPY.ru.newOrder,
      body: COPY.ru.orderPlaced(customer.phone, 2),
    });
    expect(lastTo(tkSuperFcm)?.title).not.toBe("New order");
  });

  it("writes the order's chat message in the customer's language", async () => {
    // One persisted row both sides read; the customer is the one it informs.
    const message = await prisma.message.findFirstOrThrow({
      where: { chatId, orderId: { not: null } },
      select: { text: true },
    });
    expect(message.text).toBe(COPY.tk.orderAccepted); // the customer is tk
    expect(message.text).not.toBe("Order accepted ✅");
  });
});
