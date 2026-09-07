import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { bindPushLogger } from "../src/notifications/push.js";
import { authHeader, cleanupUsers, createUserWithToken, type App } from "./helpers.js";

// FCM is never configured in the test suite, and that is exactly the deployment
// this file is about. A push-less API used to answer a broadcast with
// {sent: N, failed: 0} and write nothing to its log, so "sent" meant "inbox
// rows written" while every phone stayed silent — the panel showed "Sent: 25"
// for a push that never left the server. The Admin SDK is stubbed at the
// firebaseAdmin seam so both halves are pinned: what the response and the log
// say when push is off, and the exact FCM payload when it is on.
const fcm = vi.hoisted(() => ({
  enabled: false,
  sendEachForMulticast: vi.fn(),
}));

vi.mock("../src/lib/firebaseAdmin.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/firebaseAdmin.js")>();
  return {
    ...actual,
    getFcmMessaging: () =>
      fcm.enabled ? { sendEachForMulticast: fcm.sendEachForMulticast } : undefined,
    getFcmDisabledReason: () => (fcm.enabled ? undefined : "test double: no service account"),
  };
});

interface MulticastCall {
  tokens: string[];
  notification?: { title?: string; body?: string };
  data?: Record<string, string>;
  android?: { priority?: string; notification?: Record<string, unknown> };
  apns?: { payload?: { aps?: Record<string, unknown> } };
}

describe("POST /notifications/broadcast — push outcome is visible", () => {
  let app: App;
  let superadminToken: string;
  let superadminId: string;
  let plainToken: string;
  let recipientId: string;
  const recipientToken = `test-broadcast-token-${Math.random().toString(36).slice(2)}`;
  const titles: string[] = [];
  const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };

  function broadcast(token: string, title: string) {
    titles.push(title);
    return app.inject({
      method: "POST",
      url: "/api/v1/notifications/broadcast",
      headers: authHeader(token),
      payload: { title, body: "broadcast test body" },
    });
  }

  beforeAll(async () => {
    app = await buildApp();
    bindPushLogger(log);
    const sa = await createUserWithToken("superadmin");
    superadminId = sa.userId;
    superadminToken = sa.token;
    const plain = await createUserWithToken("user");
    plainToken = plain.token;
    recipientId = plain.userId;
    // A registered device, so the enabled-path test has a token to find.
    await prisma.userFcmToken.create({
      data: { userId: recipientId, token: recipientToken, platform: "android" },
    });
  });

  afterAll(async () => {
    // A broadcast writes a row for EVERY user, not just the fixtures.
    await prisma.userNotification.deleteMany({ where: { title: { in: titles } } });
    await cleanupUsers([superadminId, recipientId]); // cascades the token row
    await app.close();
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("plain user -> 403, unauthenticated -> 401", async () => {
    const forbidden = await broadcast(plainToken, `authz-${recipientToken}`);
    expect(forbidden.statusCode).toBe(403);
    const anon = await app.inject({
      method: "POST",
      url: "/api/v1/notifications/broadcast",
      payload: { title: "anon", body: "anon" },
    });
    expect(anon.statusCode).toBe(401);
  });

  it("with FCM disabled: writes the inbox rows, says push is off, and logs why", async () => {
    fcm.enabled = false;
    const title = `disabled-${recipientToken}`;
    const res = await broadcast(superadminToken, title);
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.sent).toBeGreaterThanOrEqual(2); // at least the two fixtures
    expect(body.failed).toBe(0);
    expect(body.pushEnabled).toBe(false);
    expect(body.pushDisabledReason).toBe("test double: no service account");

    const row = await prisma.userNotification.findFirst({ where: { userId: recipientId, title } });
    expect(row).not.toBeNull();

    // The push runs after the response; the warn is what the owner greps for
    // on the production log, and it must carry the boot-time reason.
    await vi.waitFor(() =>
      expect(log.warn).toHaveBeenCalledWith(
        expect.objectContaining({ reason: "test double: no service account" }),
        "push skipped: FCM disabled"
      )
    );
    expect(fcm.sendEachForMulticast).not.toHaveBeenCalled();
  });

  it("with FCM enabled: pushes on the announcements channel, tagged, typed, no wake-up", async () => {
    fcm.enabled = true;
    fcm.sendEachForMulticast.mockImplementation(async (msg: MulticastCall) => ({
      successCount: msg.tokens.length,
      failureCount: 0,
      responses: msg.tokens.map(() => ({ success: true })),
    }));
    const title = `enabled-${recipientToken}`;
    const res = await broadcast(superadminToken, title);
    expect(res.statusCode).toBe(200);
    expect(res.json().pushEnabled).toBe(true);
    expect(res.json().pushDisabledReason).toBeUndefined();

    await vi.waitFor(() => expect(log.info).toHaveBeenCalledWith(expect.anything(), "broadcast push done"));
    const calls = fcm.sendEachForMulticast.mock.calls.map((c) => c[0] as MulticastCall);
    const msg = calls.find((m) => m.tokens.includes(recipientToken));
    expect(msg).toBeDefined();
    expect(msg!.notification).toEqual({ title, body: "broadcast test body" });
    expect(msg!.data).toEqual({ type: "broadcast" });
    // The channel MainActivity.kt creates at IMPORTANCE_HIGH; without it FCM
    // would drop the notification on the manifest default and it could not be
    // muted separately from chat.
    expect(msg!.android?.priority).toBe("high");
    expect(msg!.android?.notification).toMatchObject({
      channelId: "announcements",
      tag: "broadcast",
      sound: "default",
    });
    expect(msg!.apns?.payload?.aps).toMatchObject({ sound: "default", threadId: "broadcast" });
    expect(msg!.apns?.payload?.aps?.contentAvailable).toBeUndefined();
    expect(log.warn).not.toHaveBeenCalled();
    fcm.enabled = false;
  });
});
