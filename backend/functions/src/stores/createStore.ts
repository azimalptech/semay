import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { db } from "../utils/firebaseAdmin";

interface CreateStoreRequest {
  name: string;
  tagline?: string;
  phone: string;
  address?: string;
  avatarUrl?: string;
  coverUrl?: string;
}

export const createStore = onCall<CreateStoreRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }
  if (request.auth.token.role !== "superadmin") {
    throw new HttpsError("permission-denied", "Super Admin only");
  }

  const { name, tagline, phone, address, avatarUrl, coverUrl } = request.data ?? {};
  if (!name || typeof name !== "string" || !name.trim()) {
    throw new HttpsError("invalid-argument", "name is required");
  }
  if (!phone || typeof phone !== "string" || !phone.trim()) {
    throw new HttpsError("invalid-argument", "phone is required");
  }

  const storeRef = db.collection("stores").doc();
  await storeRef.set({
    name: name.trim(),
    tagline: tagline?.trim() ?? "",
    avatarUrl: avatarUrl ?? "",
    coverUrl: coverUrl ?? "",
    phone: phone.trim(),
    address: address?.trim() ?? "",
    geopoint: null,
    adminIds: [],
    postsCount: 0,
    reelsCount: 0,
    createdBy: request.auth.uid,
    createdAt: FieldValue.serverTimestamp(),
    active: true,
  });

  return { success: true, storeId: storeRef.id };
});
