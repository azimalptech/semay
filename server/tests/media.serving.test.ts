import { mkdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { MEDIA_DIR } from "../src/media/storage.js";
import { authHeader, createUserWithToken, type App } from "./helpers.js";

// No test used to actually FETCH a media file, which let a crash-on-first-request
// bug in the static mount's setHeaders hook pass both typecheck and the full
// suite. Any request for a stored file would take the whole process down — a
// trivially triggerable denial of service. These tests exercise the real byte-
// serving path so that can't regress.
describe("media serving", () => {
  let app: App;
  const key = "posts/test-serving-fixture.jpg";
  const userIds: string[] = [];

  beforeAll(async () => {
    app = await buildApp();
    await mkdir(path.join(MEDIA_DIR, "posts"), { recursive: true });
    await writeFile(path.join(MEDIA_DIR, key), "fixture-bytes");
  });

  afterAll(async () => {
    await app.close();
    await unlink(path.join(MEDIA_DIR, key)).catch(() => {});
  });

  it("serves a stored file with hardening headers instead of crashing", async () => {
    const res = await app.inject({ method: "GET", url: `/media/${key}` });

    expect(res.statusCode).toBe(200);
    expect(res.body).toBe("fixture-bytes");
    // User-supplied bytes served from the API's own origin must never be
    // sniffable into an active content type or able to run script.
    expect(res.headers["x-content-type-options"]).toBe("nosniff");
    expect(String(res.headers["content-security-policy"])).toContain("default-src 'none'");
    expect(String(res.headers["cache-control"])).toContain("immutable");
  });

  it("does not expose files outside the media directory", async () => {
    // Percent-encoded traversal, so it survives path normalization on the way in.
    const res = await app.inject({ method: "GET", url: "/media/..%2f..%2fpackage.json" });
    expect(res.statusCode).toBeGreaterThanOrEqual(400);
  });

  it("refuses to mint an upload slot for an executable extension", async () => {
    const admin = await createUserWithToken("superadmin");
    userIds.push(admin.userId);

    // html/svg/js served from this origin would be stored XSS against every
    // user, including the superadmin panel's session.
    for (const fileExt of ["html", "svg", "js", "htm", "xml"]) {
      const res = await app.inject({
        method: "POST",
        url: "/api/v1/media/upload-url",
        headers: authHeader(admin.token),
        payload: { fileExt, folder: "posts" },
      });
      expect(res.statusCode, `extension ${fileExt} must be rejected`).toBe(400);
    }

    const ok = await app.inject({
      method: "POST",
      url: "/api/v1/media/upload-url",
      headers: authHeader(admin.token),
      payload: { fileExt: "JPG", folder: "posts" }, // case-insensitive allowlist
      });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().publicUrl).toMatch(/\.jpg$/);
  });
});
