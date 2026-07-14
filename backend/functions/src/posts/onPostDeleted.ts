import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { db, storage, bucketName } from "../utils/firebaseAdmin";
import { adjustCounter } from "../utils/counters";

export const onPostDeleted = onDocumentDeleted("posts/{postId}", async (event) => {
  const post = event.data?.data();
  const postId = event.params.postId;
  if (!post) return;

  const field = post.type === "reel" ? "reelsCount" : "postsCount";
  await adjustCounter(db.collection("stores").doc(post.storeId), field, -1);

  await db.recursiveDelete(db.collection("posts").doc(postId));

  await storage.bucket(bucketName).deleteFiles({
    prefix: `stores/${post.storeId}/posts/${postId}/`,
  });
});
