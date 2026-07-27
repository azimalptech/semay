import { PrismaClient } from "@prisma/client";

// BigInt (post_media.id, messages.id, and other AUTO_INCREMENT BIGINT PKs) has
// no native JSON representation — JSON.stringify throws without this. Stringify
// rather than Number() since these can exceed Number.MAX_SAFE_INTEGER.
declare global {
  interface BigInt {
    toJSON(): string;
  }
}
BigInt.prototype.toJSON = function (this: bigint): string {
  return this.toString();
};

// Single shared Prisma client for the process. Fastify is single-instance here,
// so a module-level singleton is correct (no per-request instantiation).
export const prisma = new PrismaClient();

export async function disconnectDb(): Promise<void> {
  await prisma.$disconnect();
}
