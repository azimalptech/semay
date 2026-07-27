// web-admin reads the same MySQL database as server/ (direct Prisma access,
// same trust perimeter the old adminDb/Firestore Admin SDK access had — see
// docs/07_MIGRATION.md Phase 8). Prisma needs its own generated client per
// project, but the schema itself must not fork: server/prisma/schema.prisma
// is the single authored source of truth, copied here before every
// dev/build/generate so the two can never silently drift apart.
import { copyFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const source = path.resolve(here, "../../server/prisma/schema.prisma");
const destDir = path.resolve(here, "../prisma");
const dest = path.join(destDir, "schema.prisma");

mkdirSync(destDir, { recursive: true });
copyFileSync(source, dest);
console.log(`Synced schema.prisma from server/ -> web-admin/prisma/schema.prisma`);
