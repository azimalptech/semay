// Changes an account's role.
//
//   node --env-file=.env scripts/set-role.mjs --phone +99363538839 --role user
//   node --env-file=.env scripts/set-role.mjs --phone +993… --role superadmin
//
// Roles are `user`, `admin`, `superadmin`. Store-admin membership is a separate
// join table (store_admins) and is NOT touched here — demoting an admin to user
// leaves those rows in place, so re-promoting restores their stores.
//
// Why this exists: role is the highest-privilege field in the system and the
// only way to change it was hand-written SQL. An UPDATE typed at 2am against
// the wrong phone number silently hands a stranger the panel, and nothing in
// the app will tell you it happened.
import { PrismaClient } from "@prisma/client";

const ROLES = ["user", "admin", "superadmin"];
const PHONE_RE = /^\+?[1-9]\d{6,14}$/;

const argv = process.argv.slice(2);
const valueOf = (f) => {
  const i = argv.indexOf(`--${f}`);
  return i === -1 ? undefined : argv[i + 1];
};
const has = (f) => argv.includes(`--${f}`);

function fail(msg) {
  console.error(`\n  ${msg}\n`);
  process.exit(1);
}

const phone = valueOf("phone");
const role = valueOf("role");

if (!phone || !role) {
  fail("Usage: node --env-file=.env scripts/set-role.mjs --phone +993… --role user|admin|superadmin");
}
if (!PHONE_RE.test(phone)) fail(`"${phone}" is not a valid phone number.`);
if (!ROLES.includes(role)) fail(`--role must be one of: ${ROLES.join(", ")}`);
if (!process.env.DATABASE_URL) fail("DATABASE_URL is not set — run with --env-file=.env");

const prisma = new PrismaClient();
try {
  const user = await prisma.user.findUnique({
    where: { phone },
    select: { id: true, name: true, role: true, deletedAt: true, passwordHash: true },
  });
  if (!user) fail(`No account exists for ${phone}.`);
  if (user.deletedAt) {
    fail(`${phone} is a deleted account (tombstoned ${user.deletedAt.toISOString()}).`);
  }
  if (user.role === role) {
    console.log(`\n  ${phone} is already "${role}" — nothing to do.\n`);
    process.exit(0);
  }

  // Refuse to remove the last superadmin. Losing the only one means nobody can
  // reach the panel, and the only way back is create-superadmin.mjs on the box
  // — recoverable, but a genuinely bad surprise to discover remotely.
  if (user.role === "superadmin" && role !== "superadmin") {
    const remaining = await prisma.user.count({
      where: { role: "superadmin", deletedAt: null, id: { not: user.id } },
    });
    if (remaining === 0 && !has("force")) {
      fail(
        `${phone} is the ONLY superadmin. Demoting it locks everyone out of the panel.\n` +
          "  Promote another account first, or pass --force if that is genuinely what you want."
      );
    }
  }

  await prisma.user.update({
    where: { id: user.id },
    data: {
      role,
      // The access JWT embeds the role, so without bumping this an already
      // issued token keeps asserting the OLD role until it expires — up to 15
      // minutes of continued superadmin access after a demotion.
      claimsVersion: { increment: 1 },
    },
  });

  // A role change is a trust change. Any session predating it must not survive,
  // or a demoted account's refresh token quietly mints fresh tokens.
  const { count } = await prisma.session.deleteMany({ where: { userId: user.id } });

  console.log(`\n  ${phone}${user.name ? ` (${user.name})` : ""}: ${user.role} -> ${role}`);
  if (count > 0) console.log(`  revoked ${count} session${count === 1 ? "" : "s"}`);
  if (user.role === "superadmin" && role !== "superadmin" && user.passwordHash) {
    console.log("  note: its password hash is retained but no longer grants panel access.");
  }
  console.log();
} finally {
  await prisma.$disconnect();
}
