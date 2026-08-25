// Creates (or re-passwords) the Super Admin account.
//
//   node --env-file=.env scripts/create-superadmin.mjs --phone +99312345678
//   node --env-file=.env scripts/create-superadmin.mjs --phone +993… --promote
//
// Why this exists: `prisma migrate deploy` creates empty tables and nothing
// else, and the superadmin is the ONE account that cannot bootstrap itself.
// Every other account signs in with phone+OTP, which self-provisions on first
// verify; the panel is password-only (auth/superadminAuth.ts), and
// POST /auth/superadmin/change-password requires the *current* password. So a
// freshly deployed database has a panel nobody can log into, and the only way
// in was hand-written SQL with a hand-generated bcrypt hash. That is a bad
// thing to improvise at 2am, so it lives here instead.
//
// The password is read from the terminal with echo off, or from the
// SUPERADMIN_PASSWORD environment variable for non-interactive use. It is
// never accepted as a command-line argument: argv is visible to every other
// user on the box via the process list (and `wmic process get commandline` on
// Windows), and it lands in shell history besides — the same reasoning as
// backup.mjs's credential handling.
import { PrismaClient } from "@prisma/client";
import bcrypt from "bcryptjs";

// Must stay in sync with BCRYPT_ROUNDS in src/auth/superadminAuth.ts — that
// module is the source of truth for how these hashes are produced and verified.
const BCRYPT_ROUNDS = 12;

// Matches changePasswordSchema in src/auth/routes.ts. That minimum is not
// arbitrary: this single password guards broadcast-to-every-user, store
// creation/deletion and cross-store order visibility, and it is the only
// brute-forceable surface in a system where everything else requires
// possession of a phone.
const MIN_PASSWORD_LENGTH = 12;

// Same shape the server accepts (phoneSchema in src/auth/routes.ts), so this
// script cannot create a row the login endpoint would never match.
const PHONE_RE = /^\+?[1-9]\d{6,14}$/;

// Terminal control bytes arriving in raw mode.
const CTRL_C = "\u0003";
const CTRL_D = "\u0004";
const BACKSPACE = "\u007f";

const argv = process.argv.slice(2);
const has = (flag) => argv.includes(`--${flag}`);
const valueOf = (flag) => {
  const i = argv.indexOf(`--${flag}`);
  return i === -1 ? undefined : argv[i + 1];
};

function fail(message) {
  console.error(`\n  ${message}\n`);
  process.exit(1);
}

/** Reads a line from the terminal without echoing it. Falls back to
 * SUPERADMIN_PASSWORD when stdin is not a TTY (CI, a scheduled task, a
 * provisioning script) — there is no third option, because accepting it as
 * argv would leak it to the process list. */
function readSecret(prompt) {
  return new Promise((resolve) => {
    if (!process.stdin.isTTY) {
      fail(
        "stdin is not a terminal, so the password cannot be prompted for.\n" +
          "  Set SUPERADMIN_PASSWORD in the environment instead, e.g.\n" +
          '    SUPERADMIN_PASSWORD="…" node --env-file=.env scripts/create-superadmin.mjs --phone +993…'
      );
    }
    process.stdout.write(prompt);
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding("utf8");

    let secret = "";
    const finish = () => {
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdin.removeListener("data", onData);
      process.stdout.write("\n");
    };
    const onData = (chunk) => {
      // A chunk can hold several characters at once (a paste, or a fast typist).
      for (const ch of chunk) {
        if (ch === "\r" || ch === "\n" || ch === CTRL_D) {
          finish();
          resolve(secret);
          return;
        }
        if (ch === CTRL_C) {
          // Restore the terminal before dying, or the operator is left with a
          // shell that has echo switched off.
          process.stdin.setRawMode(false);
          process.stdout.write("\n");
          process.exit(130);
        }
        if (ch === BACKSPACE || ch === "\b") {
          secret = secret.slice(0, -1);
        } else {
          secret += ch;
        }
      }
    };
    process.stdin.on("data", onData);
  });
}

async function main() {
  const phone = valueOf("phone");
  if (!phone) {
    fail(
      "Usage: node --env-file=.env scripts/create-superadmin.mjs --phone +99312345678 [--promote] [--name \"…\"]"
    );
  }
  if (!PHONE_RE.test(phone)) {
    fail(`"${phone}" is not a valid phone number (expected E.164, e.g. +99312345678).`);
  }
  if (!process.env.DATABASE_URL) {
    fail("DATABASE_URL is not set — run this with --env-file=.env");
  }

  const prisma = new PrismaClient();
  try {
    const existing = await prisma.user.findUnique({
      where: { phone },
      select: { id: true, name: true, role: true, deletedAt: true },
    });

    // A tombstoned row is an account someone deleted (users/service.ts scrubs
    // it in place rather than removing it, because orders still reference it).
    // Silently reviving one as superadmin would be a genuinely surprising
    // outcome, so refuse and make the operator pick a different number.
    if (existing?.deletedAt) {
      fail(
        `${phone} belongs to a deleted account (tombstoned ${existing.deletedAt.toISOString()}).\n` +
          "  Reviving it as a superadmin is almost certainly not what you want."
      );
    }

    // Guard against the obvious catastrophe: a typo'd digit lands on a real
    // customer's number and hands them superadmin. Promoting an existing
    // non-superadmin therefore has to be said out loud with --promote.
    if (existing && existing.role !== "superadmin" && !has("promote")) {
      fail(
        `${phone} already exists as role "${existing.role}"` +
          (existing.name ? ` (${existing.name})` : "") +
          ".\n  Re-run with --promote if you really mean to make this account a superadmin."
      );
    }

    const fromEnv = process.env.SUPERADMIN_PASSWORD;
    let password;
    if (fromEnv) {
      password = fromEnv;
    } else {
      password = await readSecret(`Password for ${phone} (min ${MIN_PASSWORD_LENGTH} chars): `);
      const confirm = await readSecret("Confirm password: ");
      if (password !== confirm) fail("Passwords did not match.");
    }

    if (password.length < MIN_PASSWORD_LENGTH) {
      fail(`Password must be at least ${MIN_PASSWORD_LENGTH} characters.`);
    }

    const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);

    const user = await prisma.user.upsert({
      where: { phone },
      create: {
        phone,
        name: valueOf("name") ?? "Super Admin",
        role: "superadmin",
        passwordHash,
      },
      update: {
        role: "superadmin",
        passwordHash,
        // Role may have changed just now; the access JWT embeds claims, so bump
        // this or an already-issued token keeps asserting the old role until it
        // expires (see getClaimsForUser / claimsVersion in the schema).
        claimsVersion: { increment: 1 },
      },
      select: { id: true, phone: true, name: true, role: true },
    });

    // Same reasoning as POST /auth/superadmin/change-password: setting a
    // password is the standard response to "someone may have my credentials",
    // so any session that predates it must not survive.
    const { count } = await prisma.session.deleteMany({ where: { userId: user.id } });

    const action = existing ? "updated" : "created";
    console.log(`\n  Superadmin ${action}.`);
    console.log(`    id     ${user.id}`);
    console.log(`    phone  ${user.phone}`);
    console.log(`    name   ${user.name}`);
    console.log(`    role   ${user.role}`);
    if (count > 0) console.log(`    (revoked ${count} existing session${count === 1 ? "" : "s"})`);
    console.log("\n  Sign in at the Super Admin panel with this phone and password.\n");
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
