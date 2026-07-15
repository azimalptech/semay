import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { getStorage } from "firebase-admin/storage";
import { getMessaging } from "firebase-admin/messaging";

if (getApps().length === 0) {
  initializeApp();
}

export const db = getFirestore();
export const auth = getAuth();
export const storage = getStorage();
export const messaging = getMessaging();

// storage.bucket() with no argument requires a default bucket configured on
// the app, which isn't populated for this project — pass this explicitly to
// every storage.bucket(...) call instead.
export const bucketName = `${process.env.GCLOUD_PROJECT}.appspot.com`;
