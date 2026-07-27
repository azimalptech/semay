import "server-only";
import { cache } from "react";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { verifyAccessToken } from "./jwt";
import { prisma } from "./db";
import { ACCESS_COOKIE } from "./authCookies";

export interface SessionClaims {
  uid: string;
  phone: string;
  role: string;
}

// The "secure" check (data-security.md's DAL pattern): proxy.ts already gates
// optimistically off the JWT alone (and silently refreshes it — see
// proxy.ts); this additionally re-reads the user's CURRENT role from the DB,
// so a demotion/revocation takes effect on this user's very next page load
// instead of riding out the access token's ~15-minute TTL. cache() memoizes
// this per request so calling it from multiple Server Components in the same
// render pass only hits the DB once.
export const getSessionClaims = cache(async (): Promise<SessionClaims | null> => {
  const token = (await cookies()).get(ACCESS_COOKIE)?.value;
  if (!token) return null;

  let userId: string;
  try {
    userId = verifyAccessToken(token).sub;
  } catch {
    return null;
  }

  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { phone: true, role: true },
  });
  if (!user || user.role !== "superadmin") return null;
  return { uid: userId, phone: user.phone, role: user.role };
});

export async function requireSuperAdmin(): Promise<SessionClaims> {
  const claims = await getSessionClaims();
  if (!claims) redirect("/login");
  return claims;
}
