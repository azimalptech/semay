import { z } from "zod";

// Fail fast at boot if the environment is misconfigured, rather than
// discovering a missing secret on the first request. Mirrors the .env.example.
const schema = z.object({
  DATABASE_URL: z.string().url(),
  PORT: z.coerce.number().int().positive().default(8080),
  WEB_ADMIN_ORIGIN: z.string().default("http://localhost:3000"),

  JWT_SECRET: z.string().min(24, "JWT_SECRET must be a long random string"),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(30),

  // Per-IP request cap (backstop against a single runaway/abusive client).
  // Kept generous by default because Turkmen carrier NAT can put many real
  // users behind one IP — precise per-user throttling lives at the auth layer
  // (per-phone OTP limits). Auth endpoints get a tighter cap (below).
  RATE_LIMIT_MAX_PER_MIN: z.coerce.number().int().positive().default(3000),
  RATE_LIMIT_AUTH_MAX_PER_MIN: z.coerce.number().int().positive().default(60),

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

  // Worker processes in cluster mode (npm run start:cluster). 0 = one per CPU
  // core. Ignored by the single-process entry point.
  CLUSTER_WORKERS: z.coerce.number().int().nonnegative().default(0),

  // Local public media folder (replaces MinIO). MEDIA_DIR is where files are
  // written on disk; MEDIA_PUBLIC_BASE_URL is where they're served from (the API
  // serves /media itself, so this is normally <api-origin>/media).
  MEDIA_DIR: z.string().default("./media"),
  MEDIA_PUBLIC_BASE_URL: z.string().default("http://localhost:8080/media"),

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
