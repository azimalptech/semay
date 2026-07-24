import { PrismaClient } from "@prisma/client";

// Single shared Prisma client for the process. Fastify is single-instance here,
// so a module-level singleton is correct (no per-request instantiation).
export const prisma = new PrismaClient();

export async function disconnectDb(): Promise<void> {
  await prisma.$disconnect();
}
