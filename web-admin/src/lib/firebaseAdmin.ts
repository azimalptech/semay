import "server-only";
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

// Mirrors backend/functions/src/utils/firebaseAdmin.ts — zero-config
// initializeApp(), relying on FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST /
// GCLOUD_PROJECT env vars (see .env.local) to redirect to the local emulator suite.
if (getApps().length === 0) {
  initializeApp();
}

export const adminAuth = getAuth();
export const adminDb = getFirestore();
export const adminStorage = getStorage();

// storage.bucket() with no argument requires a default bucket configured on
// the app, which isn't populated here — pass this explicitly, same as the
// Cloud Functions side (backend/functions/src/utils/firebaseAdmin.ts).
export const bucketName = `${process.env.GCLOUD_PROJECT}.firebasestorage.app`;
