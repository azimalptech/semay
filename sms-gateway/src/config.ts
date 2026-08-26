import { z } from "zod";

// Fail fast at boot on a bad environment rather than discovering it on the
// first login attempt — same reasoning as the app server's config.ts.
const schema = z.object({
  DATABASE_URL: z.string().url(),
  PORT: z.coerce.number().int().positive().default(8081),

  // The SeMay API authenticates to us with these (HTTP Basic).
  API_USER: z.string().min(1),
  API_PASSWORD: z.string().min(16, "API_PASSWORD must be at least 16 characters"),

  ASSIGN_TIMEOUT_SECONDS: z.coerce.number().int().positive().default(45),
  MAX_ATTEMPTS: z.coerce.number().int().positive().default(3),

  SIM_MAX_PER_HOUR: z.coerce.number().int().positive().default(60),
  SIM_MAX_PER_DAY: z.coerce.number().int().positive().default(300),
  SIM_MIN_INTERVAL_MS: z.coerce.number().int().nonnegative().default(6000),

  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  // eslint-disable-next-line no-console
  console.error(
    "Invalid environment configuration:\n" +
      parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n")
  );
  process.exit(1);
}

export const config = parsed.data;
export type Config = typeof config;
