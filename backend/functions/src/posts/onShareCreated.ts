import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { db } from "../utils/firebaseAdmin";
import { adjustCounter } from "../utils/counters";

// Unique-sharer counter — posts/{postId}/shares/{uid} (doc id = sharer uid,
// see PostsService.recordShare) only ever gets *created* once per sharer,
// mirrors onViewCreated's reasoning exactly: a plain +1 here is correct
// without a before/after check since this fires exactly once per unique
// sharer.
export const onShareCreated = onDocumentCreated("posts/{postId}/shares/{uid}", async (event) => {
  await adjustCounter(db.collection("posts").doc(event.params.postId), "sharesCount", 1);
});
