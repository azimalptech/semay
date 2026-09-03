import { existsSync, readFileSync } from "node:fs";
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
//
// The key is also checked against FIREBASE_PROJECT_ID before it is used. A key
// generated in the wrong Firebase project (or a web/app config saved under the
// same name) loads without complaint and then fails every send, long after
// boot and with nothing in the boot log to point at. Refusing up front, with
// both project ids in the reason, makes that a one-line fix — and logging which
// account is sending lets it be matched against the app's firebase_options.dart.
let messaging: Messaging | undefined;
let disabledReason: string | undefined;
let identity: FcmIdentity | undefined;

export interface FcmIdentity {
  projectId: string;
  clientEmail: string;
}

export type ServiceAccountCheck =
  | { ok: true; identity: FcmIdentity }
  | { ok: false; reason: string };

/** Reads and sanity-checks a service-account JSON without touching the SDK:
 * the file must exist, parse, be a `service_account` key carrying the three
 * fields the Admin SDK signs with, and belong to `expectedProjectId` when one
 * is configured. Pure, so tests/fcm.credentials.test.ts exercises it directly. */
export function inspectServiceAccount(
  credentialPath: string,
  expectedProjectId: string
): ServiceAccountCheck {
  if (!existsSync(credentialPath)) {
    return { ok: false, reason: `service account file not found at ${credentialPath}` };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(credentialPath, "utf8"));
  } catch (err) {
    return {
      ok: false,
      reason: `service account file is not valid JSON: ${(err as Error).message}`,
    };
  }
  const key = (parsed && typeof parsed === "object" ? parsed : {}) as Record<string, unknown>;
  if (key.type !== "service_account") {
    return {
      ok: false,
      reason:
        `${credentialPath} is not a service-account key (type=${String(key.type ?? "missing")}) — ` +
        "generate one under Project settings → Service accounts, not an app/web config",
    };
  }
  for (const field of ["project_id", "client_email", "private_key"] as const) {
    const value = key[field];
    if (typeof value !== "string" || value.length === 0) {
      return { ok: false, reason: `service account key is missing "${field}"` };
    }
  }
  const projectId = key.project_id as string;
  const clientEmail = key.client_email as string;
  if (expectedProjectId && projectId !== expectedProjectId) {
    return {
      ok: false,
      reason:
        `service account belongs to Firebase project "${projectId}" but FIREBASE_PROJECT_ID is ` +
        `"${expectedProjectId}" — every send would fail; generate the key in the right project or fix .env`,
    };
  }
  return { ok: true, identity: { projectId, clientEmail } };
}

function initMessaging(): void {
  if (!config.GOOGLE_APPLICATION_CREDENTIALS) {
    disabledReason = "GOOGLE_APPLICATION_CREDENTIALS is not set";
    return;
  }
  const credentialPath = path.resolve(config.GOOGLE_APPLICATION_CREDENTIALS);
  const check = inspectServiceAccount(credentialPath, config.FIREBASE_PROJECT_ID);
  if (!check.ok) {
    disabledReason = check.reason;
    return;
  }
  try {
    const app: App =
      getApps()[0] ??
      initializeApp({
        credential: cert(credentialPath),
        // Verified above to equal FIREBASE_PROJECT_ID whenever that is set.
        projectId: check.identity.projectId,
      });
    messaging = getMessaging(app);
    identity = check.identity;
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

/** The project and service account actually sending, once push is enabled —
 * logged at boot next to the disabled reason's absence, so an operator can
 * confirm the server and the app (firebase_options.dart) name the same project. */
export function getFcmIdentity(): FcmIdentity | undefined {
  return identity;
}
