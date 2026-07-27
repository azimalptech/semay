import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// vitest has no built-in .env loading (we deliberately avoided a dotenv
// dependency and use Node's --env-file for the app itself); replicate the
// same minimal loading here so config.ts's Zod validation sees real values.
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
      // Quoted value: take exactly what's between the quotes and ignore anything
      // after the closing quote (e.g. an inline `# comment`). The old code only
      // stripped quotes when the value both started AND ended with one, so a
      // quoted value followed by a comment kept its quotes — which broke
      // `new URL(...)` on e.g. MEDIA_PUBLIC_BASE_URL.
      const quote = value[0];
      const end = value.indexOf(quote, 1);
      value = end === -1 ? value.slice(1) : value.slice(1, end);
    } else {
      // Unquoted values may carry a trailing `# comment` (e.g. "900   # 15 min").
      value = value.replace(/\s+#.*$/, "").trim();
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}
