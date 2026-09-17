import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import { config } from "../config.js";
import {
  isAndroidUserAgent,
  pickLang,
  renderNotFoundPage,
  renderSharePage,
  renderTooManyPage,
  type ShareKind,
} from "./html.js";

// The five PUBLIC, unauthenticated routes this API serves outside /api/v1:
//
//   GET /p/:id  /r/:id  /s/:id                  the share page (HTML)
//   GET /.well-known/assetlinks.json            Android App Links
//   GET /.well-known/apple-app-site-association iOS Universal Links
//
// Everything a share link touches lives here, and the file deliberately
// imports neither prisma nor anything under ../auth: in "generic" mode (the
// only mode — config.ts SHARE_PAGE_MODE) the page is the same bytes for every
// id, so a share link can never be used to probe which post or store ids
// exist, and no unauthenticated stranger can put load on the database. See
// docs/08_OPERATIONS.md §6f.

// Ids are UUIDs everywhere in the schema (prisma/schema.prisma). Anything else
// is a mangled or hand-typed link and gets the 404 page — matching the app's
// own parser, which refuses to push a screen for it (share_links.dart).
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

// Tightened from helmet's API-wide policy for these replies only. helmet's
// default allows script-src 'self'; this page contains no <script> at all, so
// say so — a stray injected tag then cannot execute even if escaping were
// ever broken. Set per-reply rather than by loosening the global policy: the
// rest of the API keeps helmet's defaults untouched.
const PAGE_CSP =
  "default-src 'none'; img-src 'self' https: data:; style-src 'unsafe-inline'; " +
  "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

/** The API's own public origin — what the share links were built from on the
 * phone (mobile/lib/core/share_links.dart derives it from API_BASE_URL the
 * same way). MEDIA_PUBLIC_BASE_URL is already required to be the real public
 * origin, so a correct deployment needs no extra variable. */
export function sharePublicBaseUrl(): string {
  // .origin on BOTH branches, deliberately. The variable this one is
  // documented as replacing — MEDIA_PUBLIC_BASE_URL — ships WITH a path
  // ("http://localhost:8080/media") in .env and .env.example, so an operator
  // copying that shape writes ".../media" here too. Left un-stripped, that
  // path would prefix the canonical URL, the og:url and the Android intent
  // fallback of every share link: dead links on someone else's phone, with
  // nothing on this side to complain. A path here is a mistake, never a
  // deployment shape, so ignore it rather than ship it.
  if (config.SHARE_PUBLIC_BASE_URL !== "") {
    return new URL(config.SHARE_PUBLIC_BASE_URL).origin;
  }
  return new URL(config.MEDIA_PUBLIC_BASE_URL).origin;
}

/** Android App Links payload. Empty fingerprint list when
 * SHARE_ANDROID_CERT_SHA256 is unset: still a valid document (Android just
 * finds nothing to delegate to), so the route answers 200 in every
 * environment and the operator's curl check shows exactly what is missing. */
export function assetLinksBody(): unknown[] {
  const fingerprints = config.SHARE_ANDROID_CERT_SHA256.split(",")
    .map((f) => f.trim().toUpperCase())
    .filter((f) => f !== "");
  if (fingerprints.length === 0) return [];
  return [
    {
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: config.SHARE_ANDROID_PACKAGE,
        sha256_cert_fingerprints: fingerprints,
      },
    },
  ];
}

/** iOS Universal Links payload, in both the legacy `paths` and the current
 * `components` form (iOS 13+ reads components, older reads paths).
 *
 * `null` — and the route then 404s — while SHARE_IOS_APP_ID is unset, which is
 * today's shipping state: the app carries no associated-domains entitlement
 * yet (docs/09 §5e). Deliberately NOT a valid-but-empty document. Apple does
 * not fetch this file from the origin; it fetches through
 * app-site-association.cdn-apple.com and CACHES what it gets. Publishing
 * `{"applinks":{"apps":[],"details":[]}}` now means the CDN can hold "this
 * site delegates nothing" for days after the entitlement and SHARE_IOS_APP_ID
 * are finally set, and Universal Links would then appear broken with no error
 * anywhere. A 404 is not cached as a negative delegation the same way, and it
 * makes the missing configuration visible in the operator's own curl check.
 * (The Android half keeps its 200 + empty array: an empty assetlinks document
 * just fails verification, harmlessly — docs/09 §5e.) */
export function appleAppSiteAssociationBody(): unknown | null {
  const appID = config.SHARE_IOS_APP_ID.trim();
  if (appID === "") return null;
  return {
    applinks: {
      apps: [],
      details: [
        {
          appID,
          paths: ["/p/*", "/r/*", "/s/*"],
          components: [{ "/": "/p/*" }, { "/": "/r/*" }, { "/": "/s/*" }],
        },
      ],
    },
  };
}

// Route-level cap on top of the global one (app.ts). Skipped under test for
// the same reason auth/routes.ts skips its own: the global limiter is not
// registered there, so route config would have nothing to attach to.
const shareRateLimit =
  process.env.NODE_ENV === "test"
    ? {}
    : {
        config: {
          rateLimit: {
            max: config.RATE_LIMIT_SHARE_MAX_PER_MIN,
            timeWindow: "1 minute",
          },
        },
      };

function langOf(req: FastifyRequest): ReturnType<typeof pickLang> {
  const query = req.query as Record<string, unknown> | undefined;
  return pickLang(query?.["lang"], req.headers["accept-language"]);
}

function sendPage(
  req: FastifyRequest,
  reply: FastifyReply,
  kind: ShareKind,
  id: string
): FastifyReply {
  const lang = langOf(req);
  reply
    .type("text/html; charset=utf-8")
    .header("Content-Security-Policy", PAGE_CSP)
    .header("X-Content-Type-Options", "nosniff")
    .header("Referrer-Policy", "no-referrer");

  if (!UUID_RE.test(id)) {
    return reply
      .code(404)
      .header("Cache-Control", "no-store")
      .send(
        renderNotFoundPage({
          lang,
          playUrl: config.SHARE_PLAY_URL,
          appStoreUrl: config.SHARE_APPSTORE_URL,
        })
      );
  }

  return reply
    // The body varies by UA (intent:// vs semay://) and by language, so a
    // shared cache must key on both or it will hand an iPhone Android's
    // intent URL.
    .header("Cache-Control", "public, max-age=60, s-maxage=300")
    .header("Vary", "User-Agent, Accept-Language")
    .send(
      renderSharePage({
        kind,
        id,
        lang,
        android: isAndroidUserAgent(req.headers["user-agent"]),
        baseUrl: sharePublicBaseUrl(),
        playUrl: config.SHARE_PLAY_URL,
        appStoreUrl: config.SHARE_APPSTORE_URL,
        androidPackage: config.SHARE_ANDROID_PACKAGE,
      })
    );
}

// The og:image. Read once at boot into memory (26 KB) rather than mounted as a
// second static root: one less filesystem surface on a public path, and it
// works identically from src/ under tsx and from dist/ under node.
const LOGO_PATH = fileURLToPath(new URL("../../public/share/semay.png", import.meta.url));

export async function shareRoutes(app: FastifyInstance): Promise<void> {
  let logo: Buffer | null = null;
  try {
    logo = await readFile(LOGO_PATH);
  } catch (err) {
    // Not fatal: the page itself renders without it, only the link preview
    // loses its image.
    app.log.warn({ err, path: LOGO_PATH }, "share: og:image asset missing");
  }

  // Every reply from THIS plugin scope is HTML for a person in a browser, so
  // the errors are too. The only one reachable in practice is the 429 from
  // shareRateLimit below: @fastify/rate-limit THROWS what its
  // errorResponseBuilder returns, so the JSON body could not be replaced at
  // the route — it has to be caught here. The rate-limit headers
  // (retry-after, x-ratelimit-*) are already on the reply when this runs and
  // are left alone. Scoped: `app.register(shareRoutes)` is an encapsulated
  // plugin, so the rest of the API keeps the JSON error shape in
  // src/lib/errors.ts untouched.
  app.setErrorHandler((err, req, reply) => {
    const raw = (err as { statusCode?: number }).statusCode ?? 500;
    const status = raw >= 400 && raw <= 599 ? raw : 500;
    // 429 is routine and already counted by the limiter; anything else here
    // is a bug on a public path and must reach the log with its stack.
    if (status !== 429) req.log.error({ err }, "share: request failed");
    const lang = langOf(req);
    const body =
      status === 429
        ? renderTooManyPage({
            lang,
            playUrl: config.SHARE_PLAY_URL,
            appStoreUrl: config.SHARE_APPSTORE_URL,
          })
        : renderNotFoundPage({
            lang,
            playUrl: config.SHARE_PLAY_URL,
            appStoreUrl: config.SHARE_APPSTORE_URL,
          });
    return reply
      .code(status)
      .type("text/html; charset=utf-8")
      .header("Content-Security-Policy", PAGE_CSP)
      .header("X-Content-Type-Options", "nosniff")
      .header("Referrer-Policy", "no-referrer")
      .header("Cache-Control", "no-store")
      .send(body);
  });

  const kinds: [string, ShareKind][] = [
    ["/p/:id", "post"],
    ["/r/:id", "reel"],
    ["/s/:id", "store"],
  ];
  for (const [path, kind] of kinds) {
    // Both spellings. Fastify's ignoreTrailingSlash is false (app.ts), so
    // `/p/<id>/` would otherwise miss these routes entirely and fall to the
    // API-wide JSON not-found handler — a browser would show
    // {"error":"NOT_FOUND"}. And `/p/<id>/` is genuinely reachable: the
    // AndroidManifest pathPrefix claims it and the app's own parser accepts
    // it (mobile/lib/core/share_links.dart), so every URL those two accept
    // must be answered here by the share handler.
    for (const spelling of [path, `${path}/`]) {
      app.get<{ Params: { id: string } }>(spelling, shareRateLimit, async (req, reply) =>
        sendPage(req, reply, kind, req.params.id)
      );
    }
  }

  app.get("/share-assets/semay.png", shareRateLimit, async (_req, reply) => {
    if (logo === null) return reply.code(404).send({ error: "NOT_FOUND" });
    return reply
      .type("image/png")
      .header("Cache-Control", "public, max-age=86400")
      .header("X-Content-Type-Options", "nosniff")
      .send(logo);
  });

  // Fetched by Android at install/update time, and by Apple's CDN. Both want
  // application/json over 200; apple-app-site-association must have NO file
  // extension.
  app.get("/.well-known/assetlinks.json", shareRateLimit, async (_req, reply) =>
    reply
      .type("application/json; charset=utf-8")
      .header("Cache-Control", "public, max-age=3600")
      .send(assetLinksBody())
  );

  app.get("/.well-known/apple-app-site-association", shareRateLimit, async (_req, reply) => {
    const body = appleAppSiteAssociationBody();
    // 404 while SHARE_IOS_APP_ID is unset — see appleAppSiteAssociationBody
    // for why an empty document must NOT be published to Apple's CDN. JSON,
    // not the HTML pages above: the only client of this path is Apple's
    // fetcher and the operator's curl.
    if (body === null) {
      return reply
        .code(404)
        .type("application/json; charset=utf-8")
        .header("Cache-Control", "no-store")
        .send({ error: "NOT_CONFIGURED" });
    }
    return reply
      .type("application/json; charset=utf-8")
      .header("Cache-Control", "public, max-age=3600")
      .send(body);
  });
}
