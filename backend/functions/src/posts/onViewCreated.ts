import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { db } from "../utils/firebaseAdmin";
import { adjustCounter } from "../utils/counters";

// Unique-viewer counter — posts/{postId}/views/{uid} (doc id = viewer uid,
// see PostsService.recordView) only ever gets *created* once per viewer,
// never updated/deleted, so onDocumentCreated alone (not onDocumentWritten,
// unlike onLikeWrite's toggleable create/delete) is enough: this fires
// exactly once per unique viewer, which is what makes a plain +1 here
// correct without needing a before/after existence check.
export const onViewCreated = onDocumentCreated("posts/{postId}/views/{uid}", async (event) => {
  await adjustCounter(db.collection("posts").doc(event.params.postId), "viewsCount", 1);
});
