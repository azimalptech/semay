import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { bindPushLogger } from "../src/notifications/push.js";
import {
  authHeader,
  cleanupStores,
  cleanupUsers,
  createStore,
  createUserWithToken,
  TEST_FIXTURE_NAME,
  type App,
} from "./helpers.js";

// The chat path is the highest-volume push and the one report (a) is about,
// and it used to return before ever reaching push.ts when FCM was off — so a
// push-less production logged "push skipped" for broadcasts and nothing for a
// day of chat traffic. Its own file rather than a case next to the broadcast
// one: the warn is rate-limited to one line a minute per process, and vitest
// gives each file a fresh module registry, so the send below is the first
// skipped push this process sees.
vi.mock("../src/lib/firebaseAdmin.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/firebaseAdmin.js")>();
  return {
    ...actual,
    getFcmMessaging: () => undefined,
    getFcmDisabledReason: () => "test double: no service account",
  };
});

describe("chat push with FCM disabled is logged", () => {
  let app: App;
  let userId: string;
  let userToken: string;
  let adminId: string;
  let storeId: string;
  const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };

  beforeAll(async () => {
    app = await buildApp();
    bindPushLogger(log);
    const user = await createUserWithToken("user");
    userId = user.userId;
    userToken = user.token;
    const admin = await createUserWithToken("admin");
    adminId = admin.userId;
    const store = await createStore(`${TEST_FIXTURE_NAME} push skip`, adminId);
    storeId = store.id;
    // The admin is the push recipient of a customer's message.
    await prisma.storeAdmin.create({ data: { storeId, userId: adminId } });
  });

  afterAll(async () => {
    await cleanupStores([storeId]); // cascades the chat, its messages and the admin row
    await cleanupUsers([userId, adminId]);
    await app.close();
  });

  it("a customer's message logs the skipped admin push with the boot-time reason", async () => {
    const created = await app.inject({
      method: "POST",
      url: "/api/v1/chats",
      headers: authHeader(userToken),
      payload: { storeId },
    });
    expect(created.statusCode).toBe(201);
    const chatId = created.json().chat.id as string;

    const sent = await app.inject({
      method: "POST",
      url: `/api/v1/chats/${chatId}/messages`,
      headers: authHeader(userToken),
      payload: { text: "hello" },
    });
    expect(sent.statusCode).toBe(201);

    // The push runs after the send returns (best-effort, detached from it);
    // `recipients` is the one store admin, so the line also shows the fan-out
    // that was dropped.
    await vi.waitFor(() =>
      expect(log.warn).toHaveBeenCalledWith(
        expect.objectContaining({ reason: "test double: no service account", recipients: 1 }),
        "push skipped: FCM disabled"
      )
    );
  });
});
