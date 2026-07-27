import "server-only";
import { PrismaClient } from "@prisma/client";

// Single shared client for the process — mirrors server/src/db.ts. Direct
// Prisma access from Server Components/Route Handlers is the same trust
// perimeter the old adminDb (Firestore Admin SDK) access had; see
// docs/07_MIGRATION.md Phase 8.
export const prisma = new PrismaClient();
