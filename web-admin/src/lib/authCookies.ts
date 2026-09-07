import type { NextResponse } from "next/server";

export const ACCESS_COOKIE = "access_token";
export const REFRESH_COOKIE = "refresh_token";

// The access cookie only has to outlive the JWT inside it (server
// ACCESS_TOKEN_TTL_SECONDS, 15 min); proxy.ts treats a missing or expired one
// as "refresh now", so a shorter cookie is harmless and a longer one buys
// nothing. The refresh cookie IS the session: the server keeps it alive until
// logout (two-year sliding expiry), so the cookie must never be what ends it.
// Browsers cap Max-Age at 400 days, and it is re-issued on every refresh, so
// for an admin who opens the panel at all it never lapses.
export const ACCESS_MAX_AGE_SECONDS = 15 * 60;
export const REFRESH_MAX_AGE_SECONDS = 400 * 24 * 60 * 60;

/** The one options object both cookie jars — NextResponse.cookies (proxy.ts,
 * Route Handler responses) and next/headers' cookies() (apiClient.ts) — take,
 * so the two can never drift apart. */
export function authCookieOptions(maxAge: number) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    maxAge,
    path: "/",
  };
}

export function setAuthCookies(
  response: NextResponse,
  accessToken: string,
  refreshToken: string
): void {
  response.cookies.set(ACCESS_COOKIE, accessToken, authCookieOptions(ACCESS_MAX_AGE_SECONDS));
  response.cookies.set(REFRESH_COOKIE, refreshToken, authCookieOptions(REFRESH_MAX_AGE_SECONDS));
}

/** Only for an explicit end of session — the server answered SESSION_INVALID,
 * or the admin logged out. Never for a refresh that merely failed to reach the
 * server: the cookies are the session, and clearing them on a 429, a 5xx or an
 * API restart is exactly what used to log the panel out every 15 minutes. */
export function clearAuthCookies(response: NextResponse): void {
  response.cookies.set(ACCESS_COOKIE, "", { maxAge: 0, path: "/" });
  response.cookies.set(REFRESH_COOKIE, "", { maxAge: 0, path: "/" });
}
