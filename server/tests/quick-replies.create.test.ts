import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
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

// The app's Add sheet never worked against MySQL: it sent
// `position: DateTime.now().millisecondsSinceEpoch` — the Firestore-era `order`
// value, ~1.79e12 — into a 32-bit `store_quick_replies.position`. That was a
// Prisma overflow 500 originally and a 400 INVALID_INPUT once the route gained
// its INT_MAX cap (de78e82); the sheet swallowed both. The app now re-reads the
// list and sends max(position) + 1. This pins both halves of the contract: the
// epoch-shaped body stays rejected (the cap is right for the column) and the
// small-int body is accepted and listed last. Who may call the route is in
// authz.matrix.test.ts.
describe("POST /api/v1/stores/:storeId/quick-replies position contract", () => {
  let app: App;
  let storeId: string;
  let adminToken: string;
  const userIds: string[] = [];

  const EPOCH_MILLIS_POSITION = 1_788_803_273_907;
  const INT_MAX = 2_147_483_647;

  function post(payload: unknown) {
    return app.inject({
      method: "POST",
      url: `/api/v1/stores/${storeId}/quick-replies`,
      headers: authHeader(adminToken),
      payload,
    });
  }

  beforeAll(async () => {
    app = await buildApp();

    const superadmin = await createUserWithToken("superadmin");
    const admin = await createUserWithToken("user");
    userIds.push(superadmin.userId, admin.userId);

    storeId = (await createStore("Quick Reply Co", superadmin.userId)).id;
    await setStoreAdmin(storeId, admin.userId, true);
    adminToken = await refreshedToken(admin.userId);
  });

  afterAll(async () => {
    // The store's rows go with its cascade.
    await cleanupStores([storeId]);
    await cleanupUsers(userIds);
    await app.close();
  });

  it("the old app body (epoch-millisecond position) -> 400 INVALID_INPUT, nothing stored", async () => {
    const res = await post({ text: "old app body", position: EPOCH_MILLIS_POSITION });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "INVALID_INPUT" });
    expect(await prisma.storeQuickReply.count({ where: { storeId, text: "old app body" } })).toBe(0);
  });

  it("the new app body (max(position) + 1) -> 201 and lists last", async () => {
    await prisma.storeQuickReply.createMany({
      data: [
        { storeId, text: "first", position: 0 },
        { storeId, text: "gap", position: 5 },
      ],
    });

    const res = await post({ text: "appended", position: 6 });
    expect(res.statusCode).toBe(201);
    expect(res.json().quickReply).toMatchObject({ storeId, text: "appended", position: 6 });

    const list = await app.inject({
      method: "GET",
      url: `/api/v1/stores/${storeId}/quick-replies`,
      headers: authHeader(adminToken),
    });
    expect(list.statusCode).toBe(200);
    expect(list.json().quickReplies.map((q: { text: string }) => q.text)).toEqual([
      "first",
      "gap",
      "appended",
    ]);
  });

  it("position omitted -> 201 at the server default 0", async () => {
    const res = await post({ text: "no position" });
    expect(res.statusCode).toBe(201);
    expect(res.json().quickReply.position).toBe(0);
  });

  it("the column max is accepted; one past it is not", async () => {
    // The app clamps at INT_MAX for a store that already holds a row at the
    // cap, so INT_MAX itself has to keep being a valid position.
    const atMax = await post({ text: "at max", position: INT_MAX });
    expect(atMax.statusCode).toBe(201);
    expect(atMax.json().quickReply.position).toBe(INT_MAX);

    const pastMax = await post({ text: "past max", position: INT_MAX + 1 });
    expect(pastMax.statusCode).toBe(400);
    expect(pastMax.json()).toEqual({ error: "INVALID_INPUT" });
  });

  it("empty and over-long text -> 400 INVALID_INPUT (what the sheet now shows)", async () => {
    expect((await post({ text: "", position: 0 })).statusCode).toBe(400);
    expect((await post({ text: "x".repeat(513), position: 0 })).statusCode).toBe(400);
  });
});
