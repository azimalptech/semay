import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import {
  appleAppSiteAssociationBody,
  assetLinksBody,
  sharePublicBaseUrl,
} from "../src/share/routes.js";
import {
  esc,
  openAppHref,
  pickLang,
  renderNotFoundPage,
  renderSharePage,
  renderTooManyPage,
} from "../src/share/html.js";
import { config } from "../src/config.js";
import type { App } from "./helpers.js";

// The public share pages — the only unauthenticated HTML the API serves.
// Two properties matter most and are asserted directly rather than implied:
//   1. generic mode reads NOTHING from the database (no existence oracle,
//      no unauthenticated DB load) — proven with a spy, not by inspection;
//   2. the page carries no JavaScript and its own CSP forbids any.
// The rate limiter itself is disabled under NODE_ENV=test (app.ts), so the
// throttling half is proven against a booted server, not here.

const ID = "288fcd06-2cad-4399-9b11-88a9365ad3a0";
const ANDROID_UA =
  "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

describe("public share pages", () => {
  let app: App;

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe.each([
    ["/p", "post"],
    ["/r", "reel"],
    ["/s", "store"],
  ])("GET %s/:id", (prefix, _kind) => {
    it("answers 200 text/html with no auth, no cookie and no JavaScript", async () => {
      const res = await app.inject({ method: "GET", url: `${prefix}/${ID}` });

      expect(res.statusCode).toBe(200);
      expect(res.headers["content-type"]).toBe("text/html; charset=utf-8");
      expect(res.headers["set-cookie"]).toBeUndefined();
      expect(res.body).not.toMatch(/<script/i);
      // No inline handlers either — the CSP below forbids them, but the
      // markup must not be relying on that.
      expect(res.body).not.toMatch(/\son[a-z]+=/i);
      expect(res.body).toContain("<!doctype html>");
    });

    it("answers the trailing-slash spelling with the same HTML page", async () => {
      // The AndroidManifest pathPrefix claims `/p/<id>/` and the app's own
      // parser accepts it (mobile/lib/core/share_links.dart), so the same URL
      // opens the app on a verified device. With ignoreTrailingSlash false it
      // used to miss these routes and fall to the API-wide JSON handler, so a
      // browser was shown {"error":"NOT_FOUND"}.
      const slash = await app.inject({ method: "GET", url: `${prefix}/${ID}/` });
      const plain = await app.inject({ method: "GET", url: `${prefix}/${ID}` });
      expect(slash.statusCode).toBe(200);
      expect(slash.headers["content-type"]).toBe("text/html; charset=utf-8");
      expect(slash.body).toBe(plain.body);
    });

    it("renders the localised HTML 404 page for a non-UUID id, never JSON", async () => {
      const res = await app.inject({
        method: "GET",
        url: `${prefix}/not-a-uuid`,
        headers: { "accept-language": "ru" },
      });
      expect(res.statusCode).toBe(404);
      expect(res.headers["content-type"]).toBe("text/html; charset=utf-8");
      expect(res.body).toContain("Ссылка не найдена");
      expect(res.body).not.toContain("NOT_FOUND");
    });

    it("sets its own CSP with no script-src at all, plus nosniff", async () => {
      const res = await app.inject({ method: "GET", url: `${prefix}/${ID}` });
      const csp = String(res.headers["content-security-policy"]);

      expect(csp).toContain("default-src 'none'");
      expect(csp).toContain("frame-ancestors 'none'");
      expect(csp).toContain("base-uri 'none'");
      expect(csp).not.toContain("script-src");
      expect(res.headers["x-content-type-options"]).toBe("nosniff");
    });

    it("is cacheable and varies on the two things the body depends on", async () => {
      const res = await app.inject({ method: "GET", url: `${prefix}/${ID}` });
      expect(res.headers["cache-control"]).toBe("public, max-age=60, s-maxage=300");
      expect(String(res.headers["vary"])).toContain("User-Agent");
      expect(String(res.headers["vary"])).toContain("Accept-Language");
    });

    it("gives Android the intent:// button and everyone else the custom scheme", async () => {
      const seg = prefix.slice(1);
      const android = await app.inject({
        method: "GET",
        url: `${prefix}/${ID}`,
        headers: { "user-agent": ANDROID_UA },
      });
      expect(android.body).toContain(
        `intent://open/${seg}/${ID}#Intent;scheme=semay;package=com.semay.semay;`
      );
      expect(android.body).toContain("S.browser_fallback_url=");
      expect(android.body).toContain(";end");
      expect(android.body).not.toContain(`href="semay://open/${seg}/${ID}"`);

      const iphone = await app.inject({
        method: "GET",
        url: `${prefix}/${ID}`,
        headers: { "user-agent": IPHONE_UA },
      });
      expect(iphone.body).toContain(`href="semay://open/${seg}/${ID}"`);
      expect(iphone.body).not.toContain("intent://");
    });

    it("carries the OpenGraph tags a chat app needs for a preview", async () => {
      const res = await app.inject({ method: "GET", url: `${prefix}/${ID}` });
      const base = sharePublicBaseUrl();
      expect(res.body).toContain(`<meta property="og:title"`);
      expect(res.body).toContain(`<meta property="og:description"`);
      expect(res.body).toContain(
        `<meta property="og:image" content="${base}/share-assets/semay.png">`
      );
      expect(res.body).toContain(
        `<meta property="og:url" content="${base}${prefix}/${ID}">`
      );
      expect(res.body).toContain(`<link rel="canonical" href="${base}${prefix}/${ID}">`);
      // Every id renders the same copy, so indexing them all would be
      // thousands of duplicate pages.
      expect(res.body).toContain(`<meta name="robots" content="noindex,follow">`);
    });

    it("404s a malformed id — as HTML, not the API's JSON error", async () => {
      for (const bad of ["not-a-uuid", "../../etc/passwd", "1", `${ID}x`]) {
        const res = await app.inject({
          method: "GET",
          url: `${prefix}/${encodeURIComponent(bad)}`,
        });
        expect(res.statusCode, bad).toBe(404);
        expect(res.headers["content-type"], bad).toBe("text/html; charset=utf-8");
        expect(res.body, bad).not.toContain('{"error"');
        expect(res.headers["cache-control"], bad).toBe("no-store");
      }
    });

    it("is Turkmen by default, Russian on ?lang=ru or Accept-Language", async () => {
      const tk = await app.inject({ method: "GET", url: `${prefix}/${ID}` });
      expect(tk.body).toContain('<html lang="tk">');
      expect(tk.body).toContain("SeMay-da aç");

      const ru = await app.inject({ method: "GET", url: `${prefix}/${ID}?lang=ru` });
      expect(ru.body).toContain('<html lang="ru">');
      expect(ru.body).toContain("Открыть в SeMay");

      const header = await app.inject({
        method: "GET",
        url: `${prefix}/${ID}`,
        headers: { "accept-language": "ru-RU,ru;q=0.9,en;q=0.8" },
      });
      expect(header.body).toContain('<html lang="ru">');

      // ?lang= wins over the header, and an unknown language falls back to tk.
      const forced = await app.inject({
        method: "GET",
        url: `${prefix}/${ID}?lang=en`,
        headers: { "accept-language": "ru" },
      });
      expect(forced.body).toContain('<html lang="en">');
      const unknown = await app.inject({
        method: "GET",
        url: `${prefix}/${ID}?lang=zz`,
        headers: { "accept-language": "de-DE,de" },
      });
      expect(unknown.body).toContain('<html lang="tk">');
    });
  });

  it("generic mode touches the database for none of the three pages", async () => {
    // The security property, asserted rather than assumed: a share link can
    // never be used to probe which post or store ids exist, and a stranger
    // with a link can never put load on the DB.
    //
    // Patched by hand, not with vi.spyOn: Prisma's model delegates are proxies
    // with no own properties, and restoring a spy on one leaves `undefined`
    // behind, breaking every later query in the file.
    const patched: { holder: Record<string, unknown>; key: string; original: unknown }[] = [];
    let calls = 0;
    for (const [holder, key] of [
      [prisma.post as unknown as Record<string, unknown>, "findUnique"],
      [prisma.post as unknown as Record<string, unknown>, "findFirst"],
      [prisma.store as unknown as Record<string, unknown>, "findUnique"],
      [prisma.store as unknown as Record<string, unknown>, "findFirst"],
    ] as const) {
      const original = holder[key];
      patched.push({ holder, key, original });
      holder[key] = (...args: unknown[]) => {
        calls += 1;
        return (original as (...a: unknown[]) => unknown)(...args);
      };
    }
    try {
      for (const url of [`/p/${ID}`, `/r/${ID}`, `/s/${ID}`]) {
        expect((await app.inject({ method: "GET", url })).statusCode).toBe(200);
      }
      expect(calls).toBe(0);
    } finally {
      for (const p of patched) p.holder[p.key] = p.original;
    }
  });

  it("the share module imports no database client at all", async () => {
    // Belt to the braces above: the routes cannot grow a query later without
    // this failing, whatever the page happens to render today.
    const dir = fileURLToPath(new URL("../src/share/", import.meta.url));
    for (const file of ["routes.ts", "html.ts"]) {
      const source = await readFile(dir + file, "utf8");
      expect(source, file).not.toMatch(/from "\.\.\/db\.js"/);
      expect(source, file).not.toMatch(/@prisma\/client/);
    }
  });

  it("renders the same bytes for a real id and a random one (no existence oracle)", async () => {
    const real = await prisma.store.findFirst({ select: { id: true } });
    const known = real?.id ?? "11111111-1111-4111-8111-111111111111";
    const random = "99999999-9999-4999-8999-999999999999";
    const a = await app.inject({ method: "GET", url: `/s/${known}` });
    const b = await app.inject({ method: "GET", url: `/s/${random}` });
    expect(a.statusCode).toBe(b.statusCode);
    // Identical apart from the id itself.
    expect(a.body.split(known).join("<ID>")).toBe(b.body.split(random).join("<ID>"));
  });

  it("serves the og:image", async () => {
    const res = await app.inject({ method: "GET", url: "/share-assets/semay.png" });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toBe("image/png");
    expect(res.rawPayload.subarray(1, 4).toString("latin1")).toBe("PNG");
  });

  describe("well-known files", () => {
    it("assetlinks.json is JSON and parses", async () => {
      const res = await app.inject({ method: "GET", url: "/.well-known/assetlinks.json" });
      expect(res.statusCode).toBe(200);
      expect(String(res.headers["content-type"])).toContain("application/json");
      expect(res.headers["cache-control"]).toBe("public, max-age=3600");
      expect(() => JSON.parse(res.body)).not.toThrow();
      expect(Array.isArray(res.json())).toBe(true);
    });

    it("apple-app-site-association 404s while SHARE_IOS_APP_ID is unset", async () => {
      // NOT a valid-but-empty document. Apple serves this file from
      // app-site-association.cdn-apple.com and caches what it fetches, so
      // publishing `{"applinks":{"apps":[],"details":[]}}` today would have
      // the CDN answering "this site delegates nothing" for days after the
      // entitlement and SHARE_IOS_APP_ID finally land — Universal Links would
      // look broken with no error anywhere. See share/routes.ts.
      expect(config.SHARE_IOS_APP_ID).toBe("");
      const res = await app.inject({
        method: "GET",
        url: "/.well-known/apple-app-site-association",
      });
      expect(res.statusCode).toBe(404);
      expect(res.headers["cache-control"]).toBe("no-store");
      expect(appleAppSiteAssociationBody()).toBeNull();
    });

    it("apple-app-site-association is JSON with no file extension once configured", async () => {
      const saved = config.SHARE_IOS_APP_ID;
      try {
        (config as { SHARE_IOS_APP_ID: string }).SHARE_IOS_APP_ID = "ABCDE12345.com.semay.semay";
        const res = await app.inject({
          method: "GET",
          url: "/.well-known/apple-app-site-association",
        });
        expect(res.statusCode).toBe(200);
        expect(String(res.headers["content-type"])).toContain("application/json");
        expect(res.headers["cache-control"]).toBe("public, max-age=3600");
        expect(res.json()).toHaveProperty("applinks");
      } finally {
        (config as { SHARE_IOS_APP_ID: string }).SHARE_IOS_APP_ID = saved;
      }
      // The `.json` spelling is NOT what Apple fetches, and must not be the
      // only one that works.
      const wrong = await app.inject({
        method: "GET",
        url: "/.well-known/apple-app-site-association.json",
      });
      expect(wrong.statusCode).toBe(404);
    });

    it("assetlinks carries the package and every configured fingerprint once set", () => {
      // The env is empty by default on a dev box, so drive the builder
      // directly — this is the shape the operator's curl check must show.
      const saved = config.SHARE_ANDROID_CERT_SHA256;
      try {
        (config as { SHARE_ANDROID_CERT_SHA256: string }).SHARE_ANDROID_CERT_SHA256 =
          "c7:6e:46:35:a8:eb:38:e6, AA:BB:CC:DD";
        const body = assetLinksBody() as {
          relation: string[];
          target: { namespace: string; package_name: string; sha256_cert_fingerprints: string[] };
        }[];
        expect(body).toHaveLength(1);
        expect(body[0]!.relation).toEqual(["delegate_permission/common.handle_all_urls"]);
        expect(body[0]!.target.namespace).toBe("android_app");
        expect(body[0]!.target.package_name).toBe("com.semay.semay");
        expect(body[0]!.target.sha256_cert_fingerprints).toEqual([
          "C7:6E:46:35:A8:EB:38:E6",
          "AA:BB:CC:DD",
        ]);
      } finally {
        (config as { SHARE_ANDROID_CERT_SHA256: string }).SHARE_ANDROID_CERT_SHA256 = saved;
      }
    });

    it("assetlinks is an empty (still valid) document while unconfigured", () => {
      const saved = config.SHARE_ANDROID_CERT_SHA256;
      try {
        (config as { SHARE_ANDROID_CERT_SHA256: string }).SHARE_ANDROID_CERT_SHA256 = "";
        expect(assetLinksBody()).toEqual([]);
      } finally {
        (config as { SHARE_ANDROID_CERT_SHA256: string }).SHARE_ANDROID_CERT_SHA256 = saved;
      }
    });

    it("AASA names the app id and the three share paths once set", () => {
      const saved = config.SHARE_IOS_APP_ID;
      try {
        (config as { SHARE_IOS_APP_ID: string }).SHARE_IOS_APP_ID = "ABCDE12345.com.semay.semay";
        const body = appleAppSiteAssociationBody() as {
          applinks: { apps: string[]; details: { appID: string; paths: string[] }[] };
        };
        expect(body.applinks.apps).toEqual([]);
        expect(body.applinks.details[0]!.appID).toBe("ABCDE12345.com.semay.semay");
        expect(body.applinks.details[0]!.paths).toEqual(["/p/*", "/r/*", "/s/*"]);
      } finally {
        (config as { SHARE_IOS_APP_ID: string }).SHARE_IOS_APP_ID = saved;
      }
    });
  });

  describe("template units", () => {
    it("escapes every HTML metacharacter, attributes included", () => {
      expect(esc(`<img src=x onerror="alert('1')">&`)).toBe(
        "&lt;img src=x onerror=&quot;alert(&#39;1&#39;)&quot;&gt;&amp;"
      );
    });

    it("renders a coming-soon badge, not a link, for an empty store URL", () => {
      const html = renderSharePage({
        kind: "post",
        id: ID,
        lang: "en",
        android: false,
        baseUrl: "https://semaycollection.com",
        playUrl: "https://play.google.com/store/apps/details?id=com.semay.semay",
        appStoreUrl: "",
        androidPackage: "com.semay.semay",
      });
      expect(html).toContain("<span>App Store · Coming soon</span>");
      expect(html).toContain('<a href="https://play.google.com/store/apps/details?id=com.semay.semay"');
      expect(html).not.toContain('href=""');

      const both = renderSharePage({
        kind: "store",
        id: ID,
        lang: "tk",
        android: false,
        baseUrl: "https://semaycollection.com",
        playUrl: "",
        appStoreUrl: "",
        androidPackage: "com.semay.semay",
      });
      expect(both).toContain("Google Play · Ýakynda");
      expect(both).toContain("App Store · Ýakynda");
      expect(both).not.toContain("<a href=\"http");
    });

    it("keeps the not-found page in the reader's language and offers the stores", () => {
      const ru = renderNotFoundPage({ lang: "ru", playUrl: "https://play", appStoreUrl: "" });
      expect(ru).toContain("Ссылка не найдена");
      expect(ru).toContain("Скоро");
    });

    it("the 429 body is a page in all three languages, with the store buttons", () => {
      // The share routes' own error handler renders this instead of
      // @fastify/rate-limit's JSON error: Turkmen mobile traffic sits behind
      // heavy carrier NAT, so a link forwarded into a large group chat can put
      // several genuine recipients into one IP bucket within a minute, and
      // they must still be able to reach the stores. (The limiter itself is
      // disabled under NODE_ENV=test — app.ts — so the 429 status is proven
      // against a booted server, not here.)
      for (const [lang, needle] of [
        ["tk", "Birsalym garaşyň"],
        ["ru", "Подождите немного"],
        ["en", "One moment"],
      ] as const) {
        const html = renderTooManyPage({ lang, playUrl: "https://play", appStoreUrl: "" });
        expect(html, lang).toContain(needle);
        expect(html, lang).toContain('<div class="stores">');
        expect(html, lang).toContain('<a href="https://play"');
        expect(html, lang).not.toMatch(/<script/i);
      }
    });

    it("sends an Android recipient WITHOUT the app to Google Play, not back here", () => {
      // S.browser_fallback_url is where Chrome goes when it cannot resolve
      // the package — precisely the "no app" case this whole page exists for.
      // It used to be this page's own canonical URL, which made the primary
      // purple CTA a silent reload for its only audience.
      const href = openAppHref({
        kind: "reel",
        id: ID,
        android: true,
        canonicalUrl: "https://semaycollection.com/r/" + ID,
        androidPackage: "com.semay.semay",
        playUrl: "https://play.google.com/store/apps/details?id=com.semay.semay",
      });
      expect(href).toBe(
        `intent://open/r/${ID}#Intent;scheme=semay;package=com.semay.semay;` +
          "S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2Fapps%2F" +
          "details%3Fid%3Dcom.semay.semay;end"
      );
      // url-encoded, so the intent string stays one token: a raw `&` from the
      // Play query string would terminate it.
      expect(href).not.toContain("&");
    });

    it("falls back to this page only when no Play listing is configured", () => {
      // SHARE_PLAY_URL empty means "no listing yet" (the page then renders
      // "Google Play · Ýakynda"). Staying put beats Chrome's own
      // Play-Store-for-package redirect to a listing nobody has confirmed.
      const href = openAppHref({
        kind: "post",
        id: ID,
        android: true,
        canonicalUrl: "https://semaycollection.com/p/" + ID,
        androidPackage: "com.semay.semay",
        playUrl: "",
      });
      expect(href).toContain(
        `S.browser_fallback_url=https%3A%2F%2Fsemaycollection.com%2Fp%2F${ID};end`
      );
    });

    it("the rendered Android page carries the configured Play URL as its fallback", () => {
      const html = renderSharePage({
        kind: "post",
        id: ID,
        lang: "tk",
        android: true,
        baseUrl: "https://semaycollection.com",
        playUrl: "https://play.google.com/store/apps/details?id=com.semay.semay",
        appStoreUrl: "",
        androidPackage: "com.semay.semay",
      });
      expect(html).toContain(
        "S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2Fapps%2F" +
          "details%3Fid%3Dcom.semay.semay;end"
      );
      expect(html).not.toContain(`S.browser_fallback_url=https%3A%2F%2Fsemaycollection.com`);
    });

    it("sharePublicBaseUrl strips a path — MEDIA_PUBLIC_BASE_URL's /media must not leak in", () => {
      // The variable this one is copied from ships WITH a path in .env and
      // .env.example, so an operator writing ".../media" here would ship
      // https://semaycollection.com/media/p/<id> as the canonical URL, the
      // og:url and the intent fallback of every shared link.
      const saved = config.SHARE_PUBLIC_BASE_URL;
      try {
        (config as { SHARE_PUBLIC_BASE_URL: string }).SHARE_PUBLIC_BASE_URL =
          "https://semaycollection.com/media/";
        expect(sharePublicBaseUrl()).toBe("https://semaycollection.com");
      } finally {
        (config as { SHARE_PUBLIC_BASE_URL: string }).SHARE_PUBLIC_BASE_URL = saved;
      }
    });

    it("pickLang honours q-values and ignores languages we do not speak", () => {
      expect(pickLang(undefined, "de-DE,de;q=0.9")).toBe("tk");
      expect(pickLang(undefined, "en;q=0.4, ru;q=0.9")).toBe("ru");
      expect(pickLang(undefined, "ru;q=0, en;q=0.5")).toBe("en");
      expect(pickLang("RU", "en")).toBe("ru");
      expect(pickLang(["ru"], "en")).toBe("en"); // array query param — not a string
    });
  });
});
