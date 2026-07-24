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

  GOOGLE_APPLICATION_CREDENTIALS: z.string().default(""),
  FIREBASE_PROJECT_ID: z.string().default(""),

  MEDIA_ENDPOINT: z.string().default(""),
  MEDIA_PUBLIC_BASE_URL: z.string().default(""),
  MEDIA_BUCKET: z.string().default("semay"),
  MEDIA_ACCESS_KEY: z.string().default(""),
  MEDIA_SECRET_KEY: z.string().default(""),
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
