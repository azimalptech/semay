import "server-only";
import { cookies } from "next/headers";
import { ACCESS_COOKIE, REFRESH_COOKIE } from "./authCookies";

const API_BASE_URL = process.env.API_BASE_URL;
if (!API_BASE_URL) {
  throw new Error("API_BASE_URL is not set");
}

// Matches authCookies.ts — duplicated rather than imported since that file's
// setAuthCookies takes a NextResponse and this needs the next/headers cookie
// jar's own .set(), a different (but equivalent) API surface.
const ACCESS_MAX_AGE_SECONDS = 15 * 60;
const REFRESH_MAX_AGE_SECONDS = 30 * 24 * 60 * 60;

export class ApiError extends Error {
  constructor(
    public status: number,
    public body: unknown
  ) {
    super(`API request failed: ${status}`);
  }
}

/** Calls the real server/ REST API — used for mutations that need its
 * transactional side effects (claims_version bumps, real FCM sends) rather
 * than a plain field write web-admin can safely do directly via Prisma. See
 * docs/07_MIGRATION.md Phase 8 for which mutations go through which path. */
export async function callApi<T = unknown>(
  path: string,
  opts: { method?: string; body?: unknown; accessToken?: string } = {}
): Promise<T> {
  const res = await fetch(`${API_BASE_URL}${path}`, {
    method: opts.method ?? "GET",
    headers: {
      // Fastify's JSON body parser rejects an empty body sent with this
      // header set (e.g. a bodyless DELETE) — only set it when there's
      // actually a body to parse.
      ...(opts.body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(opts.accessToken ? { Authorization: `Bearer ${opts.accessToken}` } : {}),
    },
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });

  const text = await res.text();
  const json: unknown = text ? JSON.parse(text) : undefined;

  if (!res.ok) {
    throw new ApiError(res.status, json);
  }
  return json as T;
}

async function refreshTokens(
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

/** Calls the real API using the caller's own cached access token and, if the
 * server rejects it as stale, refreshes once and retries before giving up.
 *
 * proxy.ts's optimistic gate only catches an EXPIRED token or a locally-cached
 * role mismatch — it deliberately never checks claims_version (that needs a DB
 * round trip it explicitly skips for performance). So a claims_version bump is
 * invisible to it, and it lets a now-stale token straight through to the real
 * API, which rejects it with 401. Without this retry, that 401 would surface
 * as a bare, unrecoverable failure in the browser for every OTHER mutating
 * action from the SAME session, until the token separately expired or the
 * operator manually logged out and back in — this is exactly what happened
 * (2026-07-30): granting store-admin bumps the TARGET user's claims_version,
 * and when a superadmin's own account was the target (self-testing the
 * feature), their own next mutation from the same browser session 401'd with
 * no path to recover short of a fresh login. Mirrors the one-shot 401 →
 * refresh → retry the mobile client's Dio interceptor already does. */
export async function callAuthedApi<T = unknown>(
  path: string,
  opts: { method?: string; body?: unknown } = {}
): Promise<T> {
  const jar = await cookies();
  const accessToken = jar.get(ACCESS_COOKIE)?.value;

  try {
    return await callApi<T>(path, { ...opts, accessToken });
  } catch (err) {
    if (!(err instanceof ApiError) || err.status !== 401) throw err;

    const refreshToken = jar.get(REFRESH_COOKIE)?.value;
    if (!refreshToken) throw err;

    const refreshed = await refreshTokens(refreshToken);
    if (!refreshed) throw err; // refresh token itself is gone — needs a real re-login

    const secure = process.env.NODE_ENV === "production";
    jar.set(ACCESS_COOKIE, refreshed.accessToken, {
      httpOnly: true,
      secure,
      sameSite: "lax",
      maxAge: ACCESS_MAX_AGE_SECONDS,
      path: "/",
    });
    jar.set(REFRESH_COOKIE, refreshed.refreshToken, {
      httpOnly: true,
      secure,
      sameSite: "lax",
      maxAge: REFRESH_MAX_AGE_SECONDS,
      path: "/",
    });

    // One retry only — if this ALSO 401s, something else is genuinely wrong
    // (account actually deleted/demoted for real), and that error should
    // reach the caller rather than being silently retried forever.
    return callApi<T>(path, { ...opts, accessToken: refreshed.accessToken });
  }
}
