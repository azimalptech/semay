import { NextResponse, type NextRequest } from "next/server";
import { verifyAccessToken } from "@/lib/jwt";
import { ACCESS_COOKIE, REFRESH_COOKIE, clearAuthCookies, setAuthCookies } from "@/lib/authCookies";
import { refreshSession } from "@/lib/refresh";

function isValidSuperadminToken(token: string | undefined): boolean {
  if (!token) return false;
  try {
    return verifyAccessToken(token).role === "superadmin";
  } catch {
    return false;
  }
}

function signedOut(request: NextRequest): NextResponse {
  if (request.nextUrl.pathname.startsWith("/api/")) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  return NextResponse.redirect(new URL("/login", request.url));
}

// The access token has expired and the API could not be reached to renew it.
// The session is intact — the cookies stay — so the page simply retries
// itself. Before, this case was indistinguishable from a dead session: redirect
// to /login and clear both cookies, which is how an API restart, a 429 burst
// or one dropped connection logged the panel out.
const RETRY_AFTER_SECONDS = 3;

function apiUnavailable(request: NextRequest): NextResponse {
  const headers = { "Retry-After": String(RETRY_AFTER_SECONDS) };
  if (request.nextUrl.pathname.startsWith("/api/")) {
    return NextResponse.json({ error: "api_unavailable" }, { status: 503, headers });
  }
  const html =
    `<!doctype html><meta charset="utf-8">` +
    `<meta http-equiv="refresh" content="${RETRY_AFTER_SECONDS}">` +
    `<title>Reconnecting…</title>` +
    `<p style="font-family:system-ui;padding:2rem">Reconnecting to the API…</p>`;
  return new NextResponse(html, {
    status: 503,
    headers: { ...headers, "Content-Type": "text/html; charset=utf-8" },
  });
}

// Optimistic, centralized gate — local JWT signature check only, no DB round
// trip (matches the old proxy's checkRevoked:false guidance). Also the ONLY
// place that can refresh a near-expired access token: Server Components
// can't set cookies mid-render, so silent renewal has to happen here, before
// the request reaches any page. src/lib/session.ts's fresh-DB-read is the
// "secure" re-check done in every page/Route Handler that actually reads
// data — this gate is not the only line of defense.
//
// It is also the only place that may END the session (clear the cookies), and
// it does so on exactly one signal: the API's own verdict that the refresh
// token is invalid. A refresh that could not be completed is a 503 with the
// cookies untouched.
export default async function proxy(request: NextRequest) {
  const accessToken = request.cookies.get(ACCESS_COOKIE)?.value;

  if (isValidSuperadminToken(accessToken)) {
    return NextResponse.next();
  }

  const refreshToken = request.cookies.get(REFRESH_COOKIE)?.value;
  if (!refreshToken) {
    return signedOut(request);
  }

  const refreshed = await refreshSession(refreshToken);
  if (!refreshed.ok) {
    if (refreshed.reason === "unavailable") return apiUnavailable(request);
    // SESSION_INVALID: logged out elsewhere, password changed, account gone.
    const response = signedOut(request);
    clearAuthCookies(response);
    return response;
  }
  if (!isValidSuperadminToken(refreshed.accessToken)) {
    // A live session, but no longer a superadmin (demoted) — the panel has
    // nothing to show it, so treat it like a dead one.
    const response = signedOut(request);
    clearAuthCookies(response);
    return response;
  }

  // Rewrite the incoming request's cookie so this same request's Server
  // Components see the fresh token, not just future requests.
  request.cookies.set(ACCESS_COOKIE, refreshed.accessToken);
  const response = NextResponse.next({ request });
  setAuthCookies(response, refreshed.accessToken, refreshed.refreshToken);
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
