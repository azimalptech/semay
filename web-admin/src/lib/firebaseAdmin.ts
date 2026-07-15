import "server-only";
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";

// Mirrors backend/functions/src/utils/firebaseAdmin.ts — zero-config
// initializeApp(), relying on FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST /
// GCLOUD_PROJECT env vars (see .env.local) to redirect to the local emulator suite.
if (getApps().length === 0) {
  initializeApp();
}

export const adminAuth = getAuth();
export const adminDb = getFirestore();
