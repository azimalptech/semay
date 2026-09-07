import "server-only";

export type RefreshResult =
  | { ok: true; accessToken: string; refreshToken: string }
  // The server's verdict on this refresh token: the session is over.
  | { ok: false; reason: "invalid" }
  // No verdict — network error, 429, 5xx. The session is intact.
  | { ok: false; reason: "unavailable" };

const inflight = new Map<string, Promise<RefreshResult>>();

/** Single-flight refresh, keyed by the refresh token.
 *
 * Every request that arrived with the same expired access cookie — a page and
 * its /api/* fetches, a hover-prefetch and the click, three tabs restored at
 * once — used to POST /auth/refresh on its own with the SAME token. Rotation
 * let exactly one win and told the rest SESSION_INVALID, which proxy.ts turned
 * into a redirect to /login plus cleared cookies: the panel logged itself out
 * on the first navigation after every 15-minute access-token expiry. Now they
 * share one call and all set the one new pair.
 *
 * Only the call in flight is shared; a settled result is forgotten at once. A
 * request that still carries the old cookie after that (the browser had not
 * applied the Set-Cookie yet) goes to the server, whose reuse grace answers it
 * with a live sibling pair — one extra session row per such race. Remembering
 * the settled pair here instead would keep re-issuing it for the grace window
 * even after /api/logout had revoked the family: a cache handing out a session
 * the server had already ended.
 *
 * Module state is per Next.js process — the single instance deployed today. A
 * second instance would fall back to the server's reuse grace (still correct,
 * one extra session row per race). */
export function refreshSession(refreshToken: string): Promise<RefreshResult> {
  const hit = inflight.get(refreshToken);
  if (hit) return hit;

  const result = callRefresh(refreshToken).finally(() => inflight.delete(refreshToken));
  inflight.set(refreshToken, result);
  return result;
}

async function callRefresh(refreshToken: string): Promise<RefreshResult> {
  let res: Response;
  try {
    res = await fetch(`${process.env.API_BASE_URL}/auth/refresh`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });
  } catch {
    return { ok: false, reason: "unavailable" };
  }
  let body: { accessToken?: string; refreshToken?: string; error?: string };
  try {
    body = (await res.json()) as typeof body;
  } catch {
    return { ok: false, reason: "unavailable" };
  }
  if (res.ok && body.accessToken && body.refreshToken) {
    return { ok: true, accessToken: body.accessToken, refreshToken: body.refreshToken };
  }
  // The one verdict on the session is the API's own, by name — the same rule
  // the mobile client applies. A bare status is not it: a 401 from whatever
  // sits in front of the API (a reverse-proxy auth rule, a WAF), a 400 from a
  // changed request shape, a 429, a 5xx, a 502 during a redeploy — none of
  // those says the session is over, and ending it on one is how the panel
  // used to log itself out.
  if (res.status === 401 && body.error === "SESSION_INVALID") {
    return { ok: false, reason: "invalid" };
  }
  return { ok: false, reason: "unavailable" };
}
