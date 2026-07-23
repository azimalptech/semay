import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { db } from "../utils/firebaseAdmin";
import { adjustCounter } from "../utils/counters";

// Unique-sender counter — posts/{postId}/sent/{uid} (doc id = sender uid, see
// PostsService.recordSent) only ever gets *created* once per sender, mirrors
// onViewCreated's reasoning exactly: a plain +1 here is correct without a
// before/after check since this fires exactly once per unique sender.
export const onSentCreated = onDocumentCreated("posts/{postId}/sent/{uid}", async (event) => {
  await adjustCounter(db.collection("posts").doc(event.params.postId), "sentCount", 1);
});
