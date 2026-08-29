import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Same minimal .env loading as the app server's test setup — vitest does no
// .env loading of its own, and the app uses Node's --env-file rather than a
// dotenv dependency.
const here = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.resolve(here, "../.env");

if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, "utf-8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (value.startsWith('"') || value.startsWith("'")) {
      const quote = value[0];
      const end = value.indexOf(quote, 1);
      value = end === -1 ? value.slice(1) : value.slice(1, end);
    } else {
      value = value.replace(/\s+#.*$/, "").trim();
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

// Pacing and caps are what several tests assert on, so pin them rather than
// inheriting whatever the developer's .env happens to say. Without this the
// suite passes or fails depending on the machine.
process.env.SIM_MIN_INTERVAL_MS = "0";
process.env.SIM_MAX_PER_HOUR = "1000";
process.env.SIM_MAX_PER_DAY = "1000";
process.env.MAX_ATTEMPTS = "3";
process.env.ASSIGN_TIMEOUT_SECONDS = "45";
