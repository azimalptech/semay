import { NextResponse, type NextRequest } from "next/server";
import { verifyAccessToken } from "@/lib/jwt";
import { ACCESS_COOKIE, REFRESH_COOKIE, clearAuthCookies, setAuthCookies } from "@/lib/authCookies";

const API_BASE_URL = process.env.API_BASE_URL;

function isValidSuperadminToken(token: string | undefined): boolean {
  if (!token) return false;
  try {
    return verifyAccessToken(token).role === "superadmin";
  } catch {
    return false;
  }
}

async function tryRefresh(
  refreshToken: string
): Promise<{ accessToken: string; refreshToken: string } | null> {
  try {
    const res = await fetch(`${API_BASE_URL}/auth/refresh`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });
    if (!res.ok) return null;
    return (await res.json()) as { accessToken: string; refreshToken: string };
  } catch {
    return null;
  }
}

// Optimistic, centralized gate — local JWT signature check only, no DB round
// trip (matches the old proxy's checkRevoked:false guidance). Also the ONLY
// place that can refresh a near-expired access token: Server Components
// can't set cookies mid-render, so silent renewal has to happen here, before
// the request reaches any page. src/lib/session.ts's fresh-DB-read is the
// "secure" re-check done in every page/Route Handler that actually reads
// data — this gate is not the only line of defense.
export default async function proxy(request: NextRequest) {
  const accessToken = request.cookies.get(ACCESS_COOKIE)?.value;

  if (isValidSuperadminToken(accessToken)) {
    return NextResponse.next();
  }

  const refreshToken = request.cookies.get(REFRESH_COOKIE)?.value;
  if (refreshToken) {
    const refreshed = await tryRefresh(refreshToken);
    if (refreshed && isValidSuperadminToken(refreshed.accessToken)) {
      // Rewrite the incoming request's cookie so this same request's
      // Server Components see the fresh token, not just future requests.
      request.cookies.set(ACCESS_COOKIE, refreshed.accessToken);
      const response = NextResponse.next({ request });
      setAuthCookies(response, refreshed.accessToken, refreshed.refreshToken);
      return response;
    }
  }

  if (request.nextUrl.pathname.startsWith("/api/")) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const response = NextResponse.redirect(new URL("/login", request.url));
  clearAuthCookies(response);
  return response;
}

export const config = {
  matcher: [
    "/dashboard/:path*",
    "/stores/:path*",
    "/broadcast/:path*",
    "/leaderboard/:path*",
    "/notification-requests/:path*",
    "/api/users/:path*",
    "/api/leaderboard/:path*",
    "/api/stores/:path*",
    "/api/notifications/:path*",
    "/api/notification-requests/:path*",
  ],
};
