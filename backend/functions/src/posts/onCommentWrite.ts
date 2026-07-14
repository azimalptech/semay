import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { db } from "../utils/firebaseAdmin";
import { adjustCounter } from "../utils/counters";

export const onCommentWrite = onDocumentWritten(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const before = event.data?.before.exists ?? false;
    const after = event.data?.after.exists ?? false;
    if (before === after) return;

    const delta = after && !before ? 1 : -1;
    await adjustCounter(db.collection("posts").doc(event.params.postId), "commentsCount", delta);
  }
);
