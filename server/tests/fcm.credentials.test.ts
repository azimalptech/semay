import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { afterAll, describe, expect, it } from "vitest";

import { inspectServiceAccount } from "../src/lib/firebaseAdmin.js";

// A service-account key generated in the wrong Firebase project — or an app/web
// config saved as serviceAccount.json by mistake — loads without complaint and
// then fails every push, long after boot. inspectServiceAccount is the boot-time
// guard against that; these pin what it accepts and the reason it gives for
// each refusal, because the reason is what an operator acts on.
const dir = mkdtempSync(path.join(tmpdir(), "semay-fcm-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

function file(name: string, body: unknown): string {
  const p = path.join(dir, name);
  writeFileSync(p, typeof body === "string" ? body : JSON.stringify(body));
  return p;
}

const PROJECT = "semay-b57ee";
const SENDER = `firebase-adminsdk-fbsvc@${PROJECT}.iam.gserviceaccount.com`;
const key = (overrides: Record<string, unknown> = {}) => ({
  type: "service_account",
  project_id: PROJECT,
  client_email: SENDER,
  private_key: "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----\n",
  ...overrides,
});

describe("inspectServiceAccount (boot-time FCM credential guard)", () => {
  it("accepts a key for the configured project and reports who is sending", () => {
    const result = inspectServiceAccount(file("ok.json", key()), PROJECT);
    expect(result).toEqual({ ok: true, identity: { projectId: PROJECT, clientEmail: SENDER } });
  });

  it("accepts any project when FIREBASE_PROJECT_ID is unset", () => {
    const result = inspectServiceAccount(file("other-ok.json", key({ project_id: "other" })), "");
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.identity.projectId).toBe("other");
  });

  it("refuses a key from another project, naming both ids", () => {
    const result = inspectServiceAccount(file("other.json", key({ project_id: "other-proj" })), PROJECT);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.reason).toContain('"other-proj"');
      expect(result.reason).toContain(`"${PROJECT}"`);
    }
  });

  it("refuses an app/web config mistaken for a service account", () => {
    // The shape `firebase apps:sdkconfig` prints — no `type`, no private key.
    const webConfig = { apiKey: "AIza…", projectId: PROJECT, messagingSenderId: "185543007684" };
    const result = inspectServiceAccount(file("web.json", webConfig), PROJECT);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toContain("not a service-account key");
  });

  it("refuses a key missing a signing field", () => {
    const { private_key: _dropped, ...withoutKey } = key();
    const result = inspectServiceAccount(file("nokey.json", withoutKey), PROJECT);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toContain('"private_key"');
  });

  it("refuses a missing file and malformed JSON without throwing", () => {
    const missing = inspectServiceAccount(path.join(dir, "nope.json"), PROJECT);
    expect(missing.ok).toBe(false);
    if (!missing.ok) expect(missing.reason).toContain("not found");

    const malformed = inspectServiceAccount(file("bad.json", "{ not json"), PROJECT);
    expect(malformed.ok).toBe(false);
    if (!malformed.ok) expect(malformed.reason).toContain("not valid JSON");
  });
});
