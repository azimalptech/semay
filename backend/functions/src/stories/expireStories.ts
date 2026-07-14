import { onSchedule } from "firebase-functions/v2/scheduler";
import { Timestamp } from "firebase-admin/firestore";
import { db, storage, bucketName } from "../utils/firebaseAdmin";

const BATCH_LIMIT = 500;

export const expireStories = onSchedule("every 60 minutes", async () => {
  const expiredSnap = await db
    .collection("stories")
    .where("expiresAt", "<=", Timestamp.now())
    .get();

  if (expiredSnap.empty) return;

  const docs = expiredSnap.docs;
  for (const doc of docs) {
    const story = doc.data();
    await storage.bucket(bucketName).deleteFiles({
      prefix: `stores/${story.storeId}/stories/${doc.id}/`,
    });
  }

  for (let i = 0; i < docs.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const doc of docs.slice(i, i + BATCH_LIMIT)) {
      batch.delete(doc.ref);
    }
    await batch.commit();
  }
});
