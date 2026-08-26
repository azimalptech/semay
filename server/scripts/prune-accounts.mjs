// Deletes every account EXCEPT a keep-list. Dry-run unless --confirm-delete.
//
//   node --env-file=.env scripts/prune-accounts.mjs --keep "+99362936253,+99363538839"
//   node --env-file=.env scripts/prune-accounts.mjs --keep "…" --confirm-delete
//
// This is a destructive, irreversible operation on real accounts, so it
// defaults to showing you what it WOULD do and makes you ask twice for the
// real thing. Take a backup first: `npm run backup`.
//
// What deletion actually removes, via onDelete: Cascade in schema.prisma:
//   sessions, FCM tokens, store-admin membership, post likes/saves/views/
//   sent/shares, story-seen rows, chats and their messages.
// What it does NOT remove: stores, posts, and their media. Those belong to a
// Store, so deleting the admin who managed one orphans it rather than
// destroying its content.
//
// Orders are the exception that will stop you: Order.userId/adminId have NO
// cascade, so an account with orders cannot be deleted at all — MySQL refuses
// on the foreign key. That is deliberate; the product anonymises accounts in
// place rather than deleting them precisely so sales history survives (see
// docs/08_OPERATIONS.md §8). This script reports such accounts and skips them
// instead of failing halfway through.
import { PrismaClient } from "@prisma/client";

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

const keepRaw = valueOf("keep");
if (!keepRaw) {
  fail('Usage: node --env-file=.env scripts/prune-accounts.mjs --keep "+993…,+993…" [--confirm-delete]');
}
if (!process.env.DATABASE_URL) fail("DATABASE_URL is not set — run with --env-file=.env");

const keep = keepRaw.split(",").map((s) => s.trim()).filter(Boolean);
if (keep.length === 0) fail("--keep must list at least one phone number.");

const prisma = new PrismaClient();
try {
  const all = await prisma.user.findMany({
    select: { id: true, phone: true, name: true, role: true },
  });

  const missing = keep.filter((k) => !all.some((u) => u.phone === k));
  if (missing.length > 0) {
    // Almost always a typo, and a typo here means deleting an account you
    // meant to keep. Refuse rather than proceed on a keep-list that does not
    // match reality.
    fail(`These --keep numbers do not exist:\n    ${missing.join("\n    ")}`);
  }

  const doomed = all.filter((u) => !keep.includes(u.phone));
  if (doomed.length === 0) {
    console.log("\n  Nothing to delete — every account is on the keep list.\n");
    process.exit(0);
  }

  // Leaving zero superadmins locks everyone out of the panel.
  const survivingSuperadmins = all.filter(
    (u) => keep.includes(u.phone) && u.role === "superadmin"
  ).length;
  if (survivingSuperadmins === 0) {
    fail("The keep list contains no superadmin — deleting would lock you out of the panel.");
  }

  console.log(`\n  Keeping ${keep.length}, deleting ${doomed.length} of ${all.length} accounts.\n`);

  const blocked = [];
  const deletable = [];
  for (const u of doomed) {
    const [asCustomer, asAdmin, stores, chats] = await Promise.all([
      prisma.order.count({ where: { userId: u.id } }),
      prisma.order.count({ where: { adminId: u.id } }),
      prisma.storeAdmin.count({ where: { userId: u.id } }),
      prisma.chat.count({ where: { userId: u.id } }),
    ]);
    const orders = asCustomer + asAdmin;
    const label = `${u.phone.padEnd(15)} ${u.role.padEnd(11)} ${(u.name || "(no name)").padEnd(14)}`;
    if (orders > 0) {
      blocked.push({ user: u, orders });
      console.log(`  SKIP   ${label} ${orders} order(s) — FK prevents deletion`);
    } else {
      deletable.push(u);
      const extra = [
        stores > 0 ? `admin of ${stores} store(s) — WILL BE ORPHANED` : null,
        chats > 0 ? `${chats} chat(s) will be destroyed` : null,
      ].filter(Boolean);
      console.log(`  DELETE ${label}${extra.length ? "  " + extra.join("; ") : ""}`);
    }
  }

  if (!has("confirm-delete")) {
    console.log(
      `\n  DRY RUN — nothing was changed.` +
        `\n  Re-run with --confirm-delete to actually delete ${deletable.length} account(s).` +
        `\n  Take a backup first: npm run backup\n`
    );
    process.exit(0);
  }

  let done = 0;
  for (const u of deletable) {
    try {
      await prisma.user.delete({ where: { id: u.id } });
      done++;
    } catch (err) {
      // Something references it that this script did not anticipate. Report
      // and continue, rather than aborting with half the work applied and no
      // record of which half.
      console.error(`  FAILED ${u.phone}: ${err.message.split("\n")[0]}`);
    }
  }

  console.log(`\n  Deleted ${done} of ${deletable.length} account(s).`);
  if (blocked.length > 0) {
    console.log(
      `  ${blocked.length} skipped for having orders. To remove those, anonymise them\n` +
        "  instead (the product's own deletion path) so the sales history survives."
    );
  }
  console.log();
} finally {
  await prisma.$disconnect();
}
