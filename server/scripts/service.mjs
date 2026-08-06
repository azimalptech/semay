// Registers (or removes) the SeMay API as a Windows service, so it survives a
// reboot instead of needing someone to remember `npm start`.
//
// Why this exists: MySQL, Redis and the API all have to be up for the app to
// work at all. Redis and MySQL are services; the API was a bare `node` process
// started by hand, so every reboot left the phone showing REQUEST_FAILED until
// somebody noticed. This closes that.
//
// Usage (both need an elevated shell — creating a service requires admin):
//   node scripts/service.mjs install
//   node scripts/service.mjs uninstall
//
// Deliberately a script rather than manual `sc create`: the wrapper needs the
// right working directory, --env-file, and a restart policy, and none of that
// should live only in someone's shell history.
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import pkg from "node-windows";

const { Service } = pkg;

const here = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = path.resolve(here, "..");
const entry = path.join(serverRoot, "dist", "index.js");
const envFile = path.join(serverRoot, ".env");

const action = process.argv[2];
if (action !== "install" && action !== "uninstall") {
  console.error("usage: node scripts/service.mjs <install|uninstall>");
  process.exit(1);
}

if (action === "install") {
  if (!existsSync(entry)) {
    console.error(`Build output missing at ${entry}\nRun \`npm run build\` first.`);
    process.exit(1);
  }
  if (!existsSync(envFile)) {
    console.error(`No .env at ${envFile} — the service would start without config.`);
    process.exit(1);
  }
}

const svc = new Service({
  name: "SeMay API",
  description:
    "SeMay self-hosted API (Fastify + Prisma/MySQL). Serves the mobile app and the Super Admin panel.",
  script: entry,
  // The app reads config via Node's own --env-file rather than a dotenv
  // dependency, so the service has to pass it too or it boots unconfigured.
  nodeOptions: [`--env-file=${envFile}`],
  workingDirectory: serverRoot,
  // Restart on crash, but back off so a genuinely broken build doesn't spin.
  wait: 2,
  grow: 0.5,
  maxRestarts: 10,
});

svc.on("install", () => {
  console.log("installed — starting…");
  svc.start();
});
svc.on("start", () => console.log("SeMay API service is running."));
svc.on("alreadyinstalled", () => console.log("Already installed; nothing to do."));
svc.on("uninstall", () => console.log("SeMay API service removed."));
svc.on("error", (err) => console.error("service error:", err));

if (action === "install") svc.install();
else svc.uninstall();
