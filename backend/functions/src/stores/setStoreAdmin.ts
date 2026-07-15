import { onCall, HttpsError } from "firebase-functions/v2/https";
import { db, auth } from "../utils/firebaseAdmin";

interface SetStoreAdminRequest {
  storeId: string;
  userId: string;
  grant: boolean;
}

export const setStoreAdmin = onCall<SetStoreAdminRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }
  if (request.auth.token.role !== "superadmin") {
    throw new HttpsError("permission-denied", "Super Admin only");
  }

  const { storeId, userId, grant } = request.data ?? {};
  if (!storeId || typeof storeId !== "string") {
    throw new HttpsError("invalid-argument", "storeId is required");
  }
  if (!userId || typeof userId !== "string") {
    throw new HttpsError("invalid-argument", "userId is required");
  }
  if (typeof grant !== "boolean") {
    throw new HttpsError("invalid-argument", "grant must be a boolean");
  }

  const storeRef = db.collection("stores").doc(storeId);
  const userRef = db.collection("users").doc(userId);

  const result = await db.runTransaction(async (tx) => {
    const [storeSnap, userSnap] = await Promise.all([tx.get(storeRef), tx.get(userRef)]);
    if (!storeSnap.exists) {
      throw new HttpsError("not-found", "Store not found");
    }
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User not found");
    }

    const userData = userSnap.data()!;
    if (grant && userData.role === "superadmin") {
      throw new HttpsError("failed-precondition", "Cannot grant store-admin to a Super Admin");
    }

    const currentAdminIds: string[] = storeSnap.data()?.adminIds ?? [];
    const currentStoreIds: string[] = userData.storeIds ?? [];

    const newAdminIds = grant
      ? Array.from(new Set([...currentAdminIds, userId]))
      : currentAdminIds.filter((id) => id !== userId);
    const newStoreIds = grant
      ? Array.from(new Set([...currentStoreIds, storeId]))
      : currentStoreIds.filter((id) => id !== storeId);

    const newRole = newStoreIds.length > 0 ? "admin" : "user";

    tx.update(storeRef, { adminIds: newAdminIds });
    tx.update(userRef, { storeIds: newStoreIds, role: newRole });

    return { role: newRole, storeIds: newStoreIds };
  });

  await auth.setCustomUserClaims(userId, { role: result.role, storeIds: result.storeIds });

  return { success: true, ...result };
});
