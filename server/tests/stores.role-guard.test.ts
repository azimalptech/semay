import { afterAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { deleteStoreCascade, setStoreAdmin } from "../src/stores/service.js";
import { createStore, createUserWithToken } from "./helpers.js";

// Real incident (2026-07-30): setStoreAdmin's grant path unconditionally set
// role='admin', so promoting a SUPERADMIN's own account as a store's admin (it
// happened while testing this exact feature) silently demoted them — locking
// them out of the superadmin panel with no error, no warning, nothing in the
// response to suggest their own role had just changed. deleteStoreCascade had
// the identical bug on the way down (straight to 'user', skipping 'admin'
// entirely). Both must now leave a superadmin's role alone in both directions.
describe("store-admin role changes never touch an existing superadmin", () => {
  const userIds: string[] = [];
  const storeIds: string[] = [];

  afterAll(async () => {
    await prisma.store.deleteMany({ where: { id: { in: storeIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  it("still promotes a plain user to admin on grant (unchanged behavior)", async () => {
    const owner = await createUserWithToken("admin");
    const plain = await createUserWithToken("user");
    userIds.push(owner.userId, plain.userId);
    const store = await createStore("Role Guard Co", owner.userId);
    storeIds.push(store.id);

    await setStoreAdmin(store.id, plain.userId, true);

    const after = await prisma.user.findUniqueOrThrow({ where: { id: plain.userId } });
    expect(after.role).toBe("admin");
  });

  it("does NOT demote a superadmin who is granted store-admin", async () => {
    const owner = await createUserWithToken("admin");
    const superadmin = await createUserWithToken("superadmin");
    userIds.push(owner.userId, superadmin.userId);
    const store = await createStore("Role Guard Co 2", owner.userId);
    storeIds.push(store.id);

    await setStoreAdmin(store.id, superadmin.userId, true);

    const after = await prisma.user.findUniqueOrThrow({ where: { id: superadmin.userId } });
    expect(after.role).toBe("superadmin");
    // The join row itself is still created — being listed as a store's admin is
    // harmless bookkeeping for a superadmin, who already passes every authz
    // check for every store regardless. Only the role field is protected.
    const link = await prisma.storeAdmin.findUnique({
      where: { storeId_userId: { storeId: store.id, userId: superadmin.userId } },
    });
    expect(link).not.toBeNull();
  });

  it("still demotes a plain admin to user when their last store-admin row is revoked", async () => {
    const owner = await createUserWithToken("admin");
    const admin = await createUserWithToken("user");
    userIds.push(owner.userId, admin.userId);
    const store = await createStore("Role Guard Co 3", owner.userId);
    storeIds.push(store.id);

    await setStoreAdmin(store.id, admin.userId, true);
    await setStoreAdmin(store.id, admin.userId, false);

    const after = await prisma.user.findUniqueOrThrow({ where: { id: admin.userId } });
    expect(after.role).toBe("user");
  });

  it("does NOT demote a superadmin when their last store-admin row is revoked", async () => {
    const owner = await createUserWithToken("admin");
    const superadmin = await createUserWithToken("superadmin");
    userIds.push(owner.userId, superadmin.userId);
    const store = await createStore("Role Guard Co 4", owner.userId);
    storeIds.push(store.id);

    await setStoreAdmin(store.id, superadmin.userId, true);
    await setStoreAdmin(store.id, superadmin.userId, false);

    const after = await prisma.user.findUniqueOrThrow({ where: { id: superadmin.userId } });
    expect(after.role).toBe("superadmin");
  });

  it("still demotes a plain admin to user when the last store they manage is deleted", async () => {
    const owner = await createUserWithToken("admin");
    const admin = await createUserWithToken("user");
    userIds.push(owner.userId, admin.userId);
    const store = await createStore("Role Guard Co 5", owner.userId);

    await setStoreAdmin(store.id, admin.userId, true);
    await deleteStoreCascade(store.id);

    const after = await prisma.user.findUniqueOrThrow({ where: { id: admin.userId } });
    expect(after.role).toBe("user");
  });

  it("does NOT demote a superadmin when the store they were listed on is deleted", async () => {
    const owner = await createUserWithToken("admin");
    const superadmin = await createUserWithToken("superadmin");
    userIds.push(owner.userId, superadmin.userId);
    const store = await createStore("Role Guard Co 6", owner.userId);

    await setStoreAdmin(store.id, superadmin.userId, true);
    await deleteStoreCascade(store.id);

    const after = await prisma.user.findUniqueOrThrow({ where: { id: superadmin.userId } });
    expect(after.role).toBe("superadmin");
  });
});
