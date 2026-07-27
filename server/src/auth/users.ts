import type { User } from "@prisma/client";
import { Prisma } from "@prisma/client";

import { prisma } from "../db.js";

/** The 1-phone-1-account lock: `users.phone` is UNIQUE NOT NULL, so a plain
 * INSERT is the concurrency primitive — on MySQL duplicate-key error (P2002)
 * the loser just re-SELECTs and returns the winner's row instead of creating
 * a second account for the same phone under concurrent signup. */
export async function findOrCreateUserByPhone(phone: string): Promise<User> {
  const existing = await prisma.user.findUnique({ where: { phone } });
  if (existing) return existing;

  try {
    return await prisma.user.create({ data: { phone } });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
      const winner = await prisma.user.findUnique({ where: { phone } });
      if (winner) return winner;
    }
    throw err;
  }
}
