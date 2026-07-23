import { onCall, HttpsError } from "firebase-functions/v2/https";
import { db, storage, bucketName, auth } from "../utils/firebaseAdmin";

interface DeleteStoreRequest {
  storeId: string;
}

// Super-Admin-only, irreversible cascade delete — everything firestore.rules'
// stores/{storeId} comment flags as orphaned by a bare doc delete (posts,
// stories, chats, orders) plus the store's own subcollections and every
// Storage object under its prefix. A raw client-side `.delete()` on the
// store doc (which the rules alone would still permit for a superadmin) is
// exactly what this function replaces.
// Kept at full cpu/default concurrency (not the project-wide 0.5/1 cap set in
// index.ts's setGlobalOptions) — this cascades through every one of a store's
// posts/stories/chats/orders/Storage objects in a single invocation, real
// work worth the extra headroom, unlike the rest of the codebase's mostly
// single-document Firestore triggers.
export const deleteStore = onCall<DeleteStoreRequest>({ cpu: 1 }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }
  if (request.auth.token.role !== "superadmin") {
    throw new HttpsError("permission-denied", "Super Admin only");
  }

  const storeId = request.data?.storeId;
  if (!storeId || typeof storeId !== "string") {
    throw new HttpsError("invalid-argument", "storeId is required");
  }

  const storeRef = db.collection("stores").doc(storeId);
  const storeSnap = await storeRef.get();
  if (!storeSnap.exists) {
    throw new HttpsError("not-found", "Store not found");
  }
  const adminIds: string[] = storeSnap.data()?.adminIds ?? [];

  // Posts — deleting each doc fires the existing onPostDeleted trigger
  // (posts/onPostDeleted.ts), which already recursively deletes the post's
  // likes subcollection and its Storage media; no need to duplicate either
  // here. The denormalized users/{uid}/liked/{postId} and
  // users/{uid}/saved/{postId} copies (see docs/02_DATA_MODEL.md) are left
  // behind, same as they already are for a regular PostsService.deletePost —
  // every screen that reads a post by id already treats "doc doesn't exist"
  // as a normal empty state (see PostDetailScreen/ImagePostDetailContent's
  // null checks), so this isn't a new class of dangling reference, just the
  // existing one at store-deletion scale.
  const postsSnap = await db.collection("posts").where("storeId", "==", storeId).get();
  await deleteDocsChunked(postsSnap.docs.map((d) => d.ref));

  // Stories + each one's views subcollection.
  const storiesSnap = await db.collection("stories").where("storeId", "==", storeId).get();
  for (const storyDoc of storiesSnap.docs) {
    await deleteCollection(storyDoc.ref.collection("views"));
  }
  await deleteDocsChunked(storiesSnap.docs.map((d) => d.ref));

  // Chats + each one's messages subcollection + its Storage media.
  const chatsSnap = await db.collection("chats").where("storeId", "==", storeId).get();
  for (const chatDoc of chatsSnap.docs) {
    await deleteCollection(chatDoc.ref.collection("messages"));
    await deleteStoragePrefix(`chats/${chatDoc.id}/`);
  }
  await deleteDocsChunked(chatsSnap.docs.map((d) => d.ref));

  // Orders.
  const ordersSnap = await db.collection("orders").where("storeId", "==", storeId).get();
  await deleteDocsChunked(ordersSnap.docs.map((d) => d.ref));

  // The store's own subcollections.
  await deleteCollection(storeRef.collection("quickReplies"));
  await deleteCollection(storeRef.collection("leaderboard"));

  // Everything under this store's Storage prefix — avatar, campaign gift
  // image, post/story media (all uploaded under stores/{storeId}/**, see
  // storage.rules).
  await deleteStoragePrefix(`stores/${storeId}/`);

  // Un-assign every admin who managed this store — same role/claims
  // transition setStoreAdmin.ts uses for a revoke, just applied to all of a
  // deleted store's admins at once instead of one at a time.
  for (const adminId of adminIds) {
    const userRef = db.collection("users").doc(adminId);
    const userSnap = await userRef.get();
    if (!userSnap.exists) continue;
    const currentStoreIds: string[] = userSnap.data()?.storeIds ?? [];
    const newStoreIds = currentStoreIds.filter((id) => id !== storeId);
    const newRole = newStoreIds.length > 0 ? "admin" : "user";
    await userRef.update({ storeIds: newStoreIds, role: newRole });
    await auth.setCustomUserClaims(adminId, { role: newRole, storeIds: newStoreIds });
  }

  // The store doc itself, last — every reference to it above has already
  // been cleaned up by this point.
  await storeRef.delete();

  return { success: true };
});

async function deleteDocsChunked(refs: FirebaseFirestore.DocumentReference[]): Promise<void> {
  // Chunked at Firestore's 500-writes-per-batch cap — a store with more
  // posts/orders/etc. than that would otherwise throw mid-cascade.
  for (let i = 0; i < refs.length; i += 500) {
    const batch = db.batch();
    for (const ref of refs.slice(i, i + 500)) batch.delete(ref);
    await batch.commit();
  }
}

async function deleteCollection(ref: FirebaseFirestore.CollectionReference): Promise<void> {
  const snap = await ref.get();
  await deleteDocsChunked(snap.docs.map((d) => d.ref));
}

async function deleteStoragePrefix(prefix: string): Promise<void> {
  try {
    await storage.bucket(bucketName).deleteFiles({ prefix });
  } catch (e) {
    // Leftover Storage objects for a deleted store are wasted space, not a
    // correctness issue — never let this block the Firestore-side cascade,
    // which is what every screen's actual read path depends on.
    console.error(`deleteStore: failed to delete Storage prefix ${prefix}`, e);
  }
}
