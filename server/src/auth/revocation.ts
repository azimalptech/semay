import { config } from "../config.js";

// Access tokens are stateless: nothing in requireAuth's fast path can tell that
// the account behind a still-unexpired JWT was deleted seconds ago. Deleting the
// user's sessions kills *refresh*, but their current access token would keep
// working for up to ACCESS_TOKEN_TTL_SECONDS — long enough to send messages or
// like posts, re-creating the very personal data deletion just removed.
//
// This is the standard fix: a revocation set bounded by the token lifetime. An
// id is only worth remembering until every token that could carry it has
// expired, so entries are dropped after exactly that long and the set stays
// small (one entry per deletion per 15 minutes) with no unbounded growth.
//
// In-process only, the same v1 scaling seam as realtime/bus.ts's EventEmitter:
// with multiple API processes each would hold its own set, and a restart clears
// it. Both cases fail *open* for at most one access-token TTL, never longer.
// Moving this to Redis is the same one-file change as the bus.
const revokedAt = new Map<string, number>();

function ttlMs(): number {
  return config.ACCESS_TOKEN_TTL_SECONDS * 1000;
}

export function revokeUserTokens(userId: string): void {
  const now = Date.now();
  revokedAt.set(userId, now);
  // Opportunistic sweep — deletions are rare enough that piggybacking on them
  // avoids needing a timer that would hold the process open.
  const cutoff = now - ttlMs();
  for (const [id, at] of revokedAt) {
    if (at <= cutoff) revokedAt.delete(id);
  }
}

export function isUserTokenRevoked(userId: string): boolean {
  const at = revokedAt.get(userId);
  if (at === undefined) return false;
  if (at <= Date.now() - ttlMs()) {
    revokedAt.delete(userId);
    return false;
  }
  return true;
}

/** Test-only reset so one test's deletion can't leak into the next. */
export function clearRevocations(): void {
  revokedAt.clear();
}
