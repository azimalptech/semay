// Database backup, with an optional restore verification.
//
//   node --env-file=.env scripts/backup.mjs              # dump + prune old
//   node --env-file=.env scripts/backup.mjs --verify     # dump, then RESTORE it
//                                                        # into a scratch schema
//                                                        # and compare row counts
//   node --env-file=.env scripts/backup.mjs --restore <file.sql.gz> --into <db>
//
// Why --verify exists: an unverified dump is a guess. mysqldump exits 0 on
// plenty of partial outputs, and the moment you actually need the file is the
// worst possible time to discover it never restored. --verify loads the dump
// into a throwaway schema, compares every table's row count plus the foreign
// key and index totals against the live database, and drops the scratch schema
// again. Run it from a scheduled task; a backup nobody tests is a backup that
// does not exist.
//
// The dump is --single-transaction, so it is a consistent snapshot of InnoDB
// tables taken without locking the app out.
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readdir, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { createGzip, createGunzip } from "node:zlib";
import { pipeline } from "node:stream/promises";

const MYSQL_BIN = process.env.MYSQL_BIN_DIR || "C:/xampp/mysql/bin";
const OUT_DIR = process.env.BACKUP_DIR || path.resolve("C:/Users/User/Desktop/semay-backups");
const KEEP = Number(process.env.BACKUP_KEEP || 14);

const has = (flag) => process.argv.includes(`--${flag}`);
const valueOf = (flag) => {
  const i = process.argv.indexOf(`--${flag}`);
  return i === -1 ? undefined : process.argv[i + 1];
};

/** Parses the connection details out of DATABASE_URL so the backup always
 * targets whatever the server itself is using — a backup script with its own
 * hardcoded credentials silently starts backing up the wrong database the day
 * the app is repointed. */
function connection() {
  const raw = process.env.DATABASE_URL;
  if (!raw) throw new Error("DATABASE_URL is not set (run with --env-file=.env)");
  const url = new URL(raw);
  return {
    host: url.hostname || "localhost",
    port: url.port || "3306",
    user: decodeURIComponent(url.username || "root"),
    password: decodeURIComponent(url.password || ""),
    database: url.pathname.replace(/^\//, ""),
  };
}

/** Credentials go in the environment, never on the command line: anything
 * passed as an argv entry is visible to every other user via the process list
 * (and to `wmic process get commandline` on Windows). */
function mysqlEnv(conn) {
  return conn.password ? { ...process.env, MYSQL_PWD: conn.password } : process.env;
}

function runTool(tool, args, conn, { stdout, stdin } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(path.join(MYSQL_BIN, tool), args, {
      env: mysqlEnv(conn),
      stdio: [stdin ? "pipe" : "ignore", stdout ? "pipe" : "inherit", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      // mysqldump warns about --routines needing extra grants and similar; only
      // a non-zero exit is a real failure.
      if (code !== 0) reject(new Error(`${tool} exited ${code}: ${stderr.trim()}`));
      else resolve({ stderr });
    });
    if (stdout) stdout(child.stdout);
    if (stdin) stdin(child.stdin);
  });
}

function query(conn, sql, database = conn.database) {
  return new Promise((resolve, reject) => {
    const args = ["-h", conn.host, "-P", conn.port, "-u", conn.user, "-N", "-B", "-e", sql];
    // Only append a schema when there is one — passing "" makes mysql.exe treat
    // the empty string as a database name and fail.
    if (database) args.push(database);
    const child = spawn(path.join(MYSQL_BIN, "mysql.exe"), args, { env: mysqlEnv(conn) });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d.toString()));
    child.stderr.on("data", (d) => (err += d.toString()));
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0
        ? // Split on \r?\n and trim every cell: mysql.exe emits CRLF on Windows,
          // and a stray \r rides along into identifiers, turning a table name
          // into `chats\r` and failing with "Incorrect table name".
          resolve(
            out
              .split(/\r?\n/)
              .filter((l) => l.length > 0)
              .map((l) => l.split("\t").map((c) => c.trim()))
          )
        : reject(new Error(err.trim()))
    );
  });
}

async function dump(conn) {
  await mkdir(OUT_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const file = path.join(OUT_DIR, `semay-${stamp}.sql.gz`);

  await runTool(
    "mysqldump.exe",
    [
      "-h", conn.host,
      "-P", conn.port,
      "-u", conn.user,
      "--single-transaction", // consistent snapshot without locking writers out
      "--routines",
      "--triggers",
      "--events",
      "--hex-blob",
      "--default-character-set=utf8mb4",
      conn.database,
    ],
    conn,
    { stdout: (s) => pipeline(s, createGzip(), createWriteStream(file)).catch(() => {}) }
  );

  // Wait for the gzip stream to settle before reporting a size.
  await new Promise((r) => setTimeout(r, 300));
  const { size } = await stat(file);
  if (size < 1024) throw new Error(`dump looks empty (${size} bytes): ${file}`);
  console.log(`dumped ${(size / 1024 / 1024).toFixed(2)} MB -> ${file}`);
  return file;
}

async function prune() {
  const files = (await readdir(OUT_DIR))
    .filter((f) => f.startsWith("semay-") && f.endsWith(".sql.gz"))
    .sort()
    .reverse();
  for (const old of files.slice(KEEP)) {
    await unlink(path.join(OUT_DIR, old));
    console.log(`pruned ${old}`);
  }
}

async function loadInto(conn, file, database) {
  await query(conn, `DROP DATABASE IF EXISTS \`${database}\`;`, "");
  await query(
    conn,
    `CREATE DATABASE \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;`,
    ""
  );
  const gunzip = file.endsWith(".gz");
  await runTool(
    "mysql.exe",
    ["-h", conn.host, "-P", conn.port, "-u", conn.user, database],
    conn,
    {
      stdin: (sink) => {
        const src = createReadStream(file);
        pipeline(gunzip ? [src, createGunzip(), sink] : [src, sink]).catch((e) => {
          console.error("restore stream failed:", e.message);
        });
      },
    }
  );
}

/** Row counts per table, plus the constraint and index totals. Comparing only
 * row counts would pass a restore that silently dropped every foreign key. */
async function fingerprint(conn, database) {
  const tables = await query(
    conn,
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema='${database}' AND table_type='BASE TABLE' ORDER BY table_name;`,
    ""
  );
  const counts = {};
  for (const [t] of tables) {
    const [[n]] = await query(conn, `SELECT COUNT(*) FROM \`${database}\`.\`${t}\`;`, "");
    counts[t] = n;
  }
  const [[fks]] = await query(
    conn,
    `SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
      WHERE table_schema='${database}' AND constraint_type='FOREIGN KEY';`,
    ""
  );
  const [[idx]] = await query(
    conn,
    `SELECT COUNT(*) FROM information_schema.STATISTICS WHERE table_schema='${database}';`,
    ""
  );
  return { counts, fks, idx };
}

async function verify(conn, file) {
  const scratch = `${conn.database}_verify`;
  console.log(`verifying restore into ${scratch}…`);

  let live;
  let restored;
  try {
    await loadInto(conn, file, scratch);
    live = await fingerprint(conn, conn.database);
    restored = await fingerprint(conn, scratch);
  } catch (err) {
    // A dump that fails to load IS the finding — but leaving a half-restored
    // schema behind turns one bad backup into a permanent piece of litter that
    // the next run then has to reason about.
    await query(conn, `DROP DATABASE IF EXISTS \`${scratch}\`;`, "").catch(() => {});
    console.error(`RESTORE VERIFICATION FAILED: ${err.message}`);
    process.exit(1);
  }

  const problems = [];
  const names = new Set([...Object.keys(live.counts), ...Object.keys(restored.counts)]);
  for (const t of [...names].sort()) {
    const a = live.counts[t];
    const b = restored.counts[t];
    if (a !== b) problems.push(`  ${t}: live ${a ?? "(missing)"} vs restored ${b ?? "(missing)"}`);
  }
  if (live.fks !== restored.fks) {
    problems.push(`  foreign keys: live ${live.fks} vs restored ${restored.fks}`);
  }
  if (live.idx !== restored.idx) {
    problems.push(`  indexes: live ${live.idx} vs restored ${restored.idx}`);
  }

  await query(conn, `DROP DATABASE \`${scratch}\`;`, "");

  if (problems.length) {
    console.error(`RESTORE VERIFICATION FAILED:\n${problems.join("\n")}`);
    process.exit(1);
  }
  console.log(
    `restore verified: ${names.size} tables, ${live.fks} foreign keys, ` +
      `${live.idx} indexes, all row counts match`
  );
}

async function main() {
  const conn = connection();

  const restoreFile = valueOf("restore");
  if (restoreFile) {
    const into = valueOf("into");
    if (!into) throw new Error("--restore requires --into <database>");
    // Guard rail: restoring over the live database is a deliberate act, not
    // something to do by forgetting an argument.
    if (into === conn.database && !has("yes-overwrite-live")) {
      throw new Error(
        `refusing to overwrite the live database "${into}" — ` +
          `re-run with --yes-overwrite-live if that is really the intent`
      );
    }
    await loadInto(conn, restoreFile, into);
    console.log(`restored ${restoreFile} -> ${into}`);
    return;
  }

  // --file verifies an EXISTING backup instead of taking a fresh one, which is
  // how you check that last month's dump is still restorable.
  const existing = valueOf("file");
  if (existing) {
    if (!has("verify")) throw new Error("--file is only meaningful with --verify");
    await verify(conn, existing);
    return;
  }

  const file = await dump(conn);
  if (has("verify")) await verify(conn, file);
  await prune();
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
