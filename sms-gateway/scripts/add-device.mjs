// Registers a sender handset and prints its bearer token ONCE.
//
//   node --env-file=.env scripts/add-device.mjs --name "samsung-a16-sim1"
//
// The token is shown exactly once because only its SHA-256 is stored (see
// prisma/schema.prisma). If it is lost, run this again with --rotate to issue
// a new one; the old token stops working immediately.
import { PrismaClient } from "@prisma/client";
import { createHash, randomBytes } from "node:crypto";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(`--${f}`);
const valueOf = (f) => {
  const i = argv.indexOf(`--${f}`);
  return i === -1 ? undefined : argv[i + 1];
};

function fail(msg) {
  console.error(`\n  ${msg}\n`);
  process.exit(1);
}

const name = valueOf("name");
if (!name) {
  fail('Usage: node --env-file=.env scripts/add-device.mjs --name "samsung-a16-sim1" [--rotate]');
}
if (!process.env.DATABASE_URL) fail("DATABASE_URL is not set — run with --env-file=.env");

const prisma = new PrismaClient();
try {
  const token = randomBytes(32).toString("base64url");
  const tokenHash = createHash("sha256").update(token).digest("hex");

  const existing = await prisma.device.findFirst({ where: { name } });
  if (existing && !has("rotate")) {
    fail(
      `A device named "${name}" already exists (id ${existing.id}).\n` +
        "  Pass --rotate to issue it a new token, or pick a different --name."
    );
  }

  const device = existing
    ? await prisma.device.update({
        where: { id: existing.id },
        data: { tokenHash, enabled: true },
      })
    : await prisma.device.create({ data: { name, tokenHash } });

  console.log(`\n  Device ${existing ? "token rotated" : "registered"}.`);
  console.log(`    id     ${device.id}`);
  console.log(`    name   ${device.name}`);
  console.log(`\n  Token (shown once — put it in the Android app):\n`);
  console.log(`    ${token}\n`);
  if (existing) {
    console.log("  The previous token for this device no longer works.\n");
  }
} finally {
  await prisma.$disconnect();
}
