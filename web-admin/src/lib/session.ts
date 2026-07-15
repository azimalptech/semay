import "server-only";
import { cache } from "react";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { adminAuth } from "./firebaseAdmin";

export interface SessionClaims {
  uid: string;
  email: string | null;
  role: string;
}

// The "secure" check (data-security.md's DAL pattern): checkRevoked: true hits
// the Auth backend, unlike proxy.ts's optimistic checkRevoked: false. cache()
// memoizes this per request so calling it from multiple Server Components in
// the same render pass only verifies the cookie once.
export const getSessionClaims = cache(async (): Promise<SessionClaims | null> => {
  const sessionCookie = (await cookies()).get("session")?.value;
  if (!sessionCookie) return null;

  try {
    const decoded = await adminAuth.verifySessionCookie(sessionCookie, true);
    if (decoded.role !== "superadmin") return null;
    return { uid: decoded.uid, email: decoded.email ?? null, role: decoded.role };
  } catch {
    return null;
  }
});

export async function requireSuperAdmin(): Promise<SessionClaims> {
  const claims = await getSessionClaims();
  if (!claims) redirect("/login");
  return claims;
}
