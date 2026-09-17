import { z } from "zod";

// Fail fast at boot if the environment is misconfigured, rather than
// discovering a missing secret on the first request. Mirrors the .env.example.
const schema = z.object({
  DATABASE_URL: z.string().url(),
  PORT: z.coerce.number().int().positive().default(8080),
  WEB_ADMIN_ORIGIN: z.string().default("http://localhost:3000"),

  JWT_SECRET: z.string().min(24, "JWT_SECRET must be a long random string"),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  // Sessions last until logout. A refresh token expires only after this long
  // WITHOUT being used: every /auth/refresh issues its successor with a fresh
  // window (sliding expiry), so a device that opens the app even once in two
  // years never sees the login screen again. Not "never": the reaper needs a
  // bound to clear the rows behind devices that are gone for good.
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(730),
  // A refresh token that was already rotated away this recently is still
  // accepted, and gets its own live successor. Without it a client whose
  // refresh RESPONSE never arrived (timeout, process suspended mid-request) is
  // left holding a dead token and its next refresh logs the device out; the
  // same window absorbs concurrent refreshes with one token (two browser
  // tabs). Outside it a replayed token is a replay and gets 401.
  REFRESH_REUSE_GRACE_SECONDS: z.coerce.number().int().nonnegative().default(60),

  // Per-IP request cap (backstop against a single runaway/abusive client).
  // Kept generous by default because Turkmen carrier NAT can put many real
  // users behind one IP — precise per-user throttling lives at the auth layer
  // (per-phone OTP limits). Auth endpoints get a tighter cap (below).
  RATE_LIMIT_MAX_PER_MIN: z.coerce.number().int().positive().default(3000),
  RATE_LIMIT_AUTH_MAX_PER_MIN: z.coerce.number().int().positive().default(60),
  // /auth/refresh and /auth/logout get their own, wider bucket. A refresh
  // token is 256 random bits (not guessable) and a refresh costs no SMS, so
  // sharing the OTP cap only meant a busy carrier NAT — or the single Next.js
  // server IP every admin-panel refresh arrives from — hit 429 on routine
  // renewals.
  RATE_LIMIT_REFRESH_MAX_PER_MIN: z.coerce.number().int().positive().default(600),

  SMS_GATEWAY_URL: z.string().default(""),
  SMS_GATEWAY_USER: z.string().default(""),
  SMS_GATEWAY_PASSWORD: z.string().default(""),
  SMS_SEND_INTERVAL_MS: z.coerce.number().int().nonnegative().default(6000),
  OTP_TTL_SECONDS: z.coerce.number().int().positive().default(300),
  OTP_RESEND_COOLDOWN_SECONDS: z.coerce.number().int().positive().default(60),
  OTP_MAX_ATTEMPTS: z.coerce.number().int().positive().default(5),
  OTP_LOCKOUT_MINUTES: z.coerce.number().int().positive().default(60),
  OTP_DEV_MODE: z
    .enum(["true", "false"])
    .default("false")
    .transform((v) => v === "true"),

  // Fixed-code login for ONE phone number — the demo account app-store
  // reviewers use, since they cannot receive an SMS on a Turkmen number.
  // Both empty (the default) disables it entirely.
  //
  // This is a deliberate authentication bypass, so it is deliberately narrow:
  // exactly one number, and otpStore refuses to authenticate it at all if the
  // account is anything other than role "user". Without that second rule the
  // blast radius of a leaked demo code would grow silently the day someone
  // promoted this number in the admin panel.
  OTP_TEST_PHONE: z.string().default(""),
  OTP_TEST_CODE: z.string().default(""),

  GOOGLE_APPLICATION_CREDENTIALS: z.string().default(""),
  FIREBASE_PROJECT_ID: z.string().default(""),

  // Cross-process pub-sub for the realtime gateway. Unset = in-process only,
  // which is correct for a single API process. REQUIRED as soon as more than one
  // process/instance serves traffic: without it a message published on one
  // process never reaches WebSocket subscribers on another, so users would
  // silently miss realtime updates. See realtime/bus.ts.
  REDIS_URL: z.string().default(""),
  // Treat an unreachable Redis as an outage rather than a degradation: after
  // 30 s without the bus, this process stops serving REALTIME — the gateway
  // refuses new subscribes and closes the sockets it is holding, and
  // /health/realtime answers 503 so the WebSocket upstream stops routing here.
  // /health/ready deliberately keeps answering 200 (everything that is not
  // realtime still works, and every box sharing one Redis crosses this
  // threshold together). Implied for cluster workers. Set it when several
  // single-process machines share one Redis — each would otherwise keep
  // serving with realtime events confined to itself, and nothing upstream
  // would notice. See realtime/bus.ts isBusRequired.
  REDIS_REQUIRED: z
    .enum(["true", "false"])
    .default("false")
    .transform((v) => v === "true"),

  // Worker processes in cluster mode (npm run start:cluster). 0 = one per CPU
  // core. Ignored by the single-process entry point.
  CLUSTER_WORKERS: z.coerce.number().int().nonnegative().default(0),

  // Local public media folder (replaces MinIO). MEDIA_DIR is where files are
  // written on disk; MEDIA_PUBLIC_BASE_URL is where they're served from (the API
  // serves /media itself, so this is normally <api-origin>/media).
  MEDIA_DIR: z.string().default("./media"),
  MEDIA_PUBLIC_BASE_URL: z.string().default("http://localhost:8080/media"),

  // ── Public share pages (share/routes.ts) ────────────────────────────────
  // The only unauthenticated HTML the API serves: GET /p/:id, /r/:id, /s/:id
  // plus the two /.well-known files. See docs/08_OPERATIONS.md §6f.
  //
  // "generic" is the only mode: the page renders the SAME copy for every id
  // and performs NO database read at all. That is a security property, not a
  // shortcut — a page that rendered the post would turn every share link into
  // an existence oracle for post/store ids and put an unauthenticated,
  // uncacheable query in front of the DB. Kept as an enum so a future
  // "content" mode is an explicit, reviewed config change rather than a diff
  // nobody notices.
  SHARE_PAGE_MODE: z.enum(["generic"]).default("generic"),
  // Origin the share links are built from — used for the canonical <link>,
  // og:url and the Android intent fallback URL. Empty = derive it from
  // MEDIA_PUBLIC_BASE_URL's origin, which is already the API's public origin,
  // so a correct deployment needs no extra variable. ORIGIN ONLY: any path
  // written here is stripped (share/routes.ts sharePublicBaseUrl takes
  // .origin), because MEDIA_PUBLIC_BASE_URL — the value this one gets copied
  // from — ends in /media, and that suffix would corrupt every shared link.
  SHARE_PUBLIC_BASE_URL: z.string().default(""),
  // Per-IP cap for the share surface specifically. Much tighter than the
  // global 3000/min: these five routes are the only ones a stranger with a
  // link can reach, they are pure HTML/JSON with no auth behind them, and a
  // real recipient loads one page once. Generous enough for a link that goes
  // viral behind one carrier NAT.
  RATE_LIMIT_SHARE_MAX_PER_MIN: z.coerce.number().int().positive().default(120),
  // Where a recipient WITHOUT the app is sent — the store buttons on the page
  // AND, for SHARE_PLAY_URL, the Android intent's S.browser_fallback_url (so
  // the primary "Open in SeMay" button lands on Play when the app is
  // missing; share/html.ts openAppHref).
  //
  // BOTH default to empty, and empty renders a "coming soon" badge instead of
  // a link. Deliberately symmetric: whether either listing is actually
  // published is an owner fact, not something to assume in a zod default. A
  // hard-coded Play URL here would have every unconfigured deployment link to
  // a listing nobody has confirmed exists — a Play 404 is strictly worse for
  // the recipient than an honest "Ýakynda". Set the real values in
  // server/.env once the listings are live (docs/09_DEPLOYMENT.md §5e).
  SHARE_PLAY_URL: z.string().default(""),
  SHARE_APPSTORE_URL: z.string().default(""),
  // Android App Links: the SHA-256 fingerprints of the certificate(s) the
  // installed APK is signed with, comma-separated (colon-separated uppercase
  // hex, as keytool prints them). MUST be the Play App Signing certificate,
  // not the upload key, or `adb shell pm get-app-links` silently reports
  // "none" forever. Empty serves an empty (valid) assetlinks document — the
  // routes still answer, verification simply cannot succeed until it is set.
  SHARE_ANDROID_CERT_SHA256: z.string().default(""),
  // iOS Universal Links: "<TEAMID>.<bundle id>", e.g. ABCDE12345.com.semay.semay.
  // Empty makes /.well-known/apple-app-site-association answer 404 rather than
  // an empty document — correct today, because the app deliberately ships
  // WITHOUT the associated-domains entitlement (Apple Developer portal work;
  // docs/09_DEPLOYMENT.md §5e) and the share page's own "Open in SeMay" button
  // is what opens the app meanwhile. The 404 matters: Apple serves this file
  // through its own CDN and caches it, so publishing an empty one would have
  // the CDN answering "delegates nothing" for days after the entitlement
  // finally lands. See share/routes.ts.
  SHARE_IOS_APP_ID: z.string().default(""),
  // The Android package the intent:// button targets. Only ever changes if
  // the applicationId does.
  SHARE_ANDROID_PACKAGE: z.string().default("com.semay.semay"),

  // Request/error logs are written as newline-delimited JSON to
  // LOG_DIR/app.<n>.log, rotated daily and pruned to LOG_RETENTION_DAYS files.
  LOG_DIR: z.string().default("./logs"),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
  LOG_RETENTION_DAYS: z.coerce.number().int().positive().default(14),
}).superRefine((cfg, ctx) => {
  // The demo-account pair is meaningless half-set, and a half-set auth bypass
  // is the kind of thing that looks configured and silently is not.
  const testPhoneSet = cfg.OTP_TEST_PHONE !== "";
  const testCodeSet = cfg.OTP_TEST_CODE !== "";
  if (testPhoneSet !== testCodeSet) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: [testPhoneSet ? "OTP_TEST_CODE" : "OTP_TEST_PHONE"],
      message: "OTP_TEST_PHONE and OTP_TEST_CODE must be set together, or both left empty",
    });
  }
  // The verify route validates codes against /^\d{6}$/ before anything else, so
  // a test code of any other shape could never be submitted — it would look
  // configured while rejecting every attempt.
  if (testCodeSet && !/^\d{6}$/.test(cfg.OTP_TEST_CODE)) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["OTP_TEST_CODE"],
      message: "OTP_TEST_CODE must be exactly 6 digits (the verify route rejects anything else)",
    });
  }

  // MEDIA_PUBLIC_BASE_URL must be https for any real host.
  //
  // It is not just where media is served from: media/routes.ts derives the
  // signed UPLOAD origin from it, so an http:// value hands the app an http
  // upload URL. Behind TLS that 301-redirects, and neither Dio nor the Android
  // client follows a redirect on a PUT — every post publish fails with an
  // opaque "status code of 301" that says nothing about the cause. The stored
  // publicUrl is then http too, which the app's network-security config
  // refuses to load at all.
  //
  // Cost us a real debugging session, and the failure appears three layers away
  // from the setting that caused it, so it is worth refusing to boot over.
  // Loopback is exempt: local development has no certificate.
  try {
    const mediaUrl = new URL(cfg.MEDIA_PUBLIC_BASE_URL);
    const isLoopback =
      mediaUrl.hostname === "localhost" ||
      mediaUrl.hostname === "127.0.0.1" ||
      mediaUrl.hostname === "::1" ||
      // The Android emulator's alias for the host machine.
      mediaUrl.hostname === "10.0.2.2";
    if (mediaUrl.protocol === "http:" && !isLoopback) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["MEDIA_PUBLIC_BASE_URL"],
        message:
          `must use https for a non-loopback host (got "${cfg.MEDIA_PUBLIC_BASE_URL}"). ` +
          "The signed media UPLOAD origin is derived from this value, so http here makes " +
          "every post publish fail on a 301 redirect the mobile client will not follow.",
      });
    }
  } catch {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["MEDIA_PUBLIC_BASE_URL"],
      message: "must be an absolute URL, e.g. https://example.com/media",
    });
  }

  // SHARE_PUBLIC_BASE_URL is what every share page advertises as its own
  // canonical URL and what the Android intent:// button falls back to. A
  // malformed value there would ship broken links to every recipient, and the
  // symptom (a link preview that resolves to nothing) appears on someone
  // else's phone, so refuse to boot on it rather than discover it in the wild.
  if (cfg.SHARE_PUBLIC_BASE_URL !== "") {
    try {
      const u = new URL(cfg.SHARE_PUBLIC_BASE_URL);
      if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("scheme");
    } catch {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["SHARE_PUBLIC_BASE_URL"],
        message: "must be an absolute http(s) origin, e.g. https://semaycollection.com (or empty to derive it from MEDIA_PUBLIC_BASE_URL)",
      });
    }
  }
  // Same for the two store links: they are rendered as <a href>, so anything
  // that is not an absolute http(s) URL is either a dead button or — with a
  // javascript: value — an injected script on a page whose whole point is
  // that it runs none. Empty is valid and means "coming soon".
  for (const key of ["SHARE_PLAY_URL", "SHARE_APPSTORE_URL"] as const) {
    if (cfg[key] === "") continue;
    try {
      const u = new URL(cfg[key]);
      if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("scheme");
    } catch {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: [key],
        message: `${key} must be an absolute http(s) URL, or empty to render a "coming soon" badge`,
      });
    }
  }

  // In production (OTP_DEV_MODE=false) real SMS must be deliverable — otherwise
  // every login silently 502s. Fail at boot instead, with a clear message.
  if (!cfg.OTP_DEV_MODE) {
    for (const key of ["SMS_GATEWAY_URL", "SMS_GATEWAY_USER", "SMS_GATEWAY_PASSWORD"] as const) {
      if (!cfg[key]) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: [key],
          message: `${key} is required when OTP_DEV_MODE=false (real SMS sending)`,
        });
      }
    }
  }
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  // eslint-disable-next-line no-console
  console.error(
    "Invalid environment configuration:\n" +
      parsed.error.issues
        .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
        .join("\n")
  );
  process.exit(1);
}

export const config = parsed.data;
export type Config = typeof config;
