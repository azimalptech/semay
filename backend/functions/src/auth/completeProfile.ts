import { onCall, HttpsError } from "firebase-functions/v2/https";
import { db } from "../utils/firebaseAdmin";

interface CompleteProfileRequest {
  name: string;
}

export const completeProfile = onCall<CompleteProfileRequest>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }

  const name = request.data?.name;
  if (!name || typeof name !== "string" || !name.trim()) {
    throw new HttpsError("invalid-argument", "name is required");
  }

  await db.collection("users").doc(request.auth.uid).update({ name: name.trim() });

  return { success: true };
});
