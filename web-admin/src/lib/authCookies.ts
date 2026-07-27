import type { NextResponse } from "next/server";

export const ACCESS_COOKIE = "access_token";
export const REFRESH_COOKIE = "refresh_token";

// Matches server/.env's ACCESS_TOKEN_TTL_SECONDS/REFRESH_TOKEN_TTL_DAYS
// defaults — cookie lifetime just needs to outlive the token itself
// comfortably; actual expiry is enforced by JWT verification, not maxAge.
const ACCESS_MAX_AGE_SECONDS = 15 * 60;
const REFRESH_MAX_AGE_SECONDS = 30 * 24 * 60 * 60;

export function setAuthCookies(
  response: NextResponse,
  accessToken: string,
  refreshToken: string
): void {
  const secure = process.env.NODE_ENV === "production";
  response.cookies.set(ACCESS_COOKIE, accessToken, {
    httpOnly: true,
    secure,
    sameSite: "lax",
    maxAge: ACCESS_MAX_AGE_SECONDS,
    path: "/",
  });
  response.cookies.set(REFRESH_COOKIE, refreshToken, {
    httpOnly: true,
    secure,
    sameSite: "lax",
    maxAge: REFRESH_MAX_AGE_SECONDS,
    path: "/",
  });
}

export function clearAuthCookies(response: NextResponse): void {
  response.cookies.set(ACCESS_COOKIE, "", { maxAge: 0, path: "/" });
  response.cookies.set(REFRESH_COOKIE, "", { maxAge: 0, path: "/" });
}
