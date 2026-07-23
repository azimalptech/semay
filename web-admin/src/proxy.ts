import { NextResponse, type NextRequest } from "next/server";
import { adminAuth } from "@/lib/firebaseAdmin";

// Optimistic, centralized gate (runs on every matched request, Node.js
// runtime by default as of Next 16). checkRevoked: false is a local JWT
// signature check only, no Auth-backend round trip — matches docs' guidance
// to keep Proxy checks cheap. src/lib/session.ts's checkRevoked: true is the
// "secure" re-check done in every page/Route Handler that actually reads
// data, per data-security.md's Data Access Layer pattern — this gate is not
// the only line of defense.
export default async function proxy(request: NextRequest) {
  const sessionCookie = request.cookies.get("session")?.value;

  let authorized = false;
  if (sessionCookie) {
    try {
      const decoded = await adminAuth.verifySessionCookie(sessionCookie, false);
      authorized = decoded.role === "superadmin";
    } catch {
      authorized = false;
    }
  }

  if (authorized) return NextResponse.next();

  if (request.nextUrl.pathname.startsWith("/api/")) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  return NextResponse.redirect(new URL("/login", request.url));
}

export const config = {
  matcher: [
    "/dashboard/:path*",
    "/stores/:path*",
    "/broadcast/:path*",
    "/leaderboard/:path*",
    "/api/users/:path*",
    "/api/leaderboard/:path*",
  ],
};
