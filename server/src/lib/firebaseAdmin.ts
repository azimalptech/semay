import { cert, getApps, initializeApp, type App } from "firebase-admin/app";
import { getMessaging, type Messaging } from "firebase-admin/messaging";

import { config } from "../config.js";

// FCM is the one Firebase dependency this migration keeps (push only — see
// docs/07_MIGRATION.md). Guarded rather than required at boot: a dev box
// without a service account should still run the rest of the API, just with
// push silently disabled instead of crashing on startup.
let messaging: Messaging | undefined;

if (config.GOOGLE_APPLICATION_CREDENTIALS) {
  const app: App = getApps()[0] ?? initializeApp({
    credential: cert(config.GOOGLE_APPLICATION_CREDENTIALS),
    projectId: config.FIREBASE_PROJECT_ID,
  });
  messaging = getMessaging(app);
}

export function getFcmMessaging(): Messaging | undefined {
  return messaging;
}
