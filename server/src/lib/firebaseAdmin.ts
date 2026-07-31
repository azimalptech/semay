import { existsSync } from "node:fs";
import path from "node:path";

import { cert, getApps, initializeApp, type App } from "firebase-admin/app";
import { getMessaging, type Messaging } from "firebase-admin/messaging";

import { config } from "../config.js";

// FCM is the one Firebase dependency this migration keeps (push only — see
// docs/07_MIGRATION.md). Initialization must never throw: the service-account
// JSON is a credential that is deliberately not committed, so a dev box, a CI
// runner, and the test suite all legitimately run without it. Push is disabled
// in that case; everything else works.
//
// `cert()` throws synchronously on a missing or malformed file, and this used to
// run unguarded at import time — which made the whole module (and therefore
// app.ts, and therefore every test importing it) fail to load. Both the
// existence check and the try/catch below are load-bearing.
let messaging: Messaging | undefined;
let disabledReason: string | undefined;

function initMessaging(): void {
  if (!config.GOOGLE_APPLICATION_CREDENTIALS) {
    disabledReason = "GOOGLE_APPLICATION_CREDENTIALS is not set";
    return;
  }
  const credentialPath = path.resolve(config.GOOGLE_APPLICATION_CREDENTIALS);
  if (!existsSync(credentialPath)) {
    disabledReason = `service account file not found at ${credentialPath}`;
    return;
  }
  try {
    const app: App =
      getApps()[0] ??
      initializeApp({
        credential: cert(credentialPath),
        projectId: config.FIREBASE_PROJECT_ID || undefined,
      });
    messaging = getMessaging(app);
  } catch (err) {
    disabledReason = `service account could not be loaded: ${(err as Error).message}`;
  }
}

initMessaging();

export function getFcmMessaging(): Messaging | undefined {
  return messaging;
}

/** Why push is unavailable, or undefined when it is working. Logged once at boot
 * (see index.ts) so a silently push-less deployment is visible in the logs
 * rather than only discovered when a notification never arrives. */
export function getFcmDisabledReason(): string | undefined {
  return disabledReason;
}
