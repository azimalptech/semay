import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { db } from "../utils/firebaseAdmin";
import { adjustCounter } from "../utils/counters";

export const onPostCreated = onDocumentCreated("posts/{postId}", async (event) => {
  const post = event.data?.data();
  if (!post) return;

  const field = post.type === "reel" ? "reelsCount" : "postsCount";
  await adjustCounter(db.collection("stores").doc(post.storeId), field, 1);
});
