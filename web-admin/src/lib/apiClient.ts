import "server-only";

const API_BASE_URL = process.env.API_BASE_URL;
if (!API_BASE_URL) {
  throw new Error("API_BASE_URL is not set");
}

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
