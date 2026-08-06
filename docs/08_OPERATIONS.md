# 08 — Operations & Scaling

Runbook for running SeMay in production. `07_MIGRATION.md` is the history of how
the backend got here; this is how to operate it. Read both before touching
deployment.

## 1. Topology

```
                    ┌─────────── Caddy / Nginx (TLS, :443) ───────────┐
                    │                                                 │
              /api/* + /ws                                    /media/*  (optional
                    │                                                   file_server
        ┌───────────┴───────────┐                                       rooted at
        │  semay-server workers │  N processes (npm run start:cluster)   MEDIA_DIR)
        │  Fastify + ws         │
        └───────┬───────┬───────┘
                │       │
          MySQL 8 │       │ Redis  (pub-sub only — no app state is stored in it)
                          │
                    FCM (push only — the sole remaining Firebase dependency)
```

Everything except FCM runs on infrastructure you control, in-country. Firebase is
used for **push notifications only**; there is no Firestore, Firebase Auth,
Firebase Storage, or Cloud Functions anywhere in the system.

## 1a. Nothing may depend on someone remembering to start it

All three moving parts run as auto-starting Windows services on the current
box. This was not always true, and the failure mode was silent: MySQL and the
API were bare processes started by hand, so any reboot left the mobile app
showing `REQUEST_FAILED` with nothing obviously broken to look at.

| Component | Service name | Start |
|---|---|---|
| MySQL (XAMPP/MariaDB) | `mysql` | Automatic |
| Redis (realtime pub-sub) | `Redis` | Automatic |
| SeMay API | `semayapi.exe` ("SeMay API") | Automatic |

The API service is defined in code, not clicked together by hand, so it can be
rebuilt from scratch:

```bash
cd server
npm run build            # the service runs dist/, so build first
npm run service:install  # elevated shell required
npm run service:uninstall
```

It passes `--env-file=.env` explicitly — the app reads config through Node's own
env-file support rather than a dotenv dependency, so a service that forgot it
would boot unconfigured — and restarts on crash with backoff, capped, so a
genuinely broken build fails visibly instead of spinning forever.

**Triage when the app can't reach the API:** `curl localhost:8080/health`. If
that fails it's the API service; if it succeeds but the phone still errors it's
the `adb reverse tcp:8080 tcp:8080` tunnel, which has to be re-run every time
the phone reconnects over USB.

## 2. What has to be true for 100k daily active users

These are ordered by what breaks first if ignored.

| # | Requirement | Why it matters | Where |
|---|---|---|---|
| 1 | **`REDIS_URL` set** whenever more than one process serves traffic | A Node process only shares realtime events with sockets it owns. Without Redis, two users on different workers never see each other's messages — the app looks fine and silently loses chat delivery. `start:cluster` refuses to boot without it. | `server/src/realtime/bus.ts` |
| 2 | **Run in cluster mode** (`npm run start:cluster`) | One Node process = one CPU core. On an 8-core box, single-process mode wastes 7/8 of the machine and is a single point of failure. | `server/src/cluster.ts` |
| 3 | **`connection_limit` × `CLUSTER_WORKERS` < MySQL `max_connections`** | This is the most common way a correctly-written app falls over under load: workers each open their own pool, exhaust `max_connections` (default 151), and every request starts failing while CPU sits idle. | `DATABASE_URL` |
| 4 | **Serve `/media/*` from Caddy/Nginx**, not Node | Media is the highest-bandwidth traffic in the app. A static file server does it with near-zero CPU; Node does it while competing with API requests for the event loop. | point `file_server` at `MEDIA_DIR` |
| 5 | **The maintenance reaper is running** | Stories and their media files, plus expired sessions, otherwise grow without bound. This was missing entirely until it was added — see §5. | `server/src/maintenance.ts` |
| 6 | **Load-test before launch** | Everything above is necessary but not sufficient. Nothing here has been tested at 100k DAU; the numbers are engineering estimates. See §7. | — |

### Sizing starting point

For one 8-core / 16 GB server:

```ini
CLUSTER_WORKERS=0                 # one per core
DATABASE_URL="mysql://…/semay?connection_limit=15&pool_timeout=20"
REDIS_URL="redis://127.0.0.1:6379"
```

8 workers × 15 connections = 120, comfortably under MySQL's 151 default. If you
raise `max_connections`, raise `connection_limit` with it — not before.

## 3. Realtime: how it scales

`realtime/bus.ts` is the only pub-sub seam. Publishing goes to Redis; local
delivery happens on the echo back through this process's subscriber connection,
so a publish is delivered exactly once per subscribed socket regardless of which
worker produced it.

Subscriptions are reference-counted per channel: Redis `SUBSCRIBE` is issued for
the first local listener and `UNSUBSCRIBE`d after the last, so Redis never pushes
traffic a process has nobody to deliver to.

Two things were fixed here that would not have survived scale:

- **Per-socket DB polling.** Each connection used to run a `claimsVersion` query
  every 30s. At 20k concurrent sockets that is ~660 queries/sec doing nothing
  almost every time, growing linearly with connections. Claims invalidation is
  now event-driven: `bumpClaimsVersion` publishes on `user:{id}:claims` and the
  socket closes in milliseconds instead of up to 30s later, at zero idle cost.
- **N+1 on subscribe.** Authorization ran two queries per channel, and an app
  launch subscribes to many channels at once (chat list, open threads, visible
  posts) — roughly 20 queries per launch. The per-connection auth context is now
  cached for 5s, collapsing a burst into one lookup while staying far fresher
  than the 15-minute access token it derives from.

## 4. Logging

Newline-delimited JSON to `LOG_DIR/app.<date>.log`, rotated daily and pruned to
`LOG_RETENTION_DAYS` files (default 14) so disk use is bounded. Console output is
pretty-printed outside production only. `LOG_LEVEL` controls verbosity.

Boot logs two things worth alerting on:

- `FCM push is DISABLED` — the service-account file is missing or unreadable, so
  no push will be delivered. The API otherwise runs normally by design.
- `realtime: in-process only` — `REDIS_URL` is unset. Fine for one process,
  **wrong for more than one** (see §2.1).

## 5. Scheduled maintenance

`server/src/maintenance.ts` runs hourly in every process, but a MySQL advisory
lock (`GET_LOCK`) means exactly one actually reaps per tick — correct across both
workers and machines, unlike a "only worker 1" convention.

| Reaped | Rule | Guard |
|---|---|---|
| Expired stories + their media files | `expiresAt` older than a 1h grace window | Grace window means a viewer mid-playback at the 24h boundary is never cut off |
| Sessions | expired, or revoked more than 7 days ago | Revoked rows are kept a while so a replayed old refresh token gets an explicit 401 rather than silently missing |
| OTP codes | expired **and** not under lockout | Deleting a locked row would reset the attempts counter and hand an attacker fresh guesses |

Stories are the biggest win: every one expires after 24h, so without this the
`stories` table and the media folder grew forever.

## 6. Security posture

Fixed during hardening, each with the reasoning that makes it non-obvious:

- **Media upload extension allowlist.** Uploads are served from the API's own
  origin, so a stored `.html`, `.svg` or `.js` would be script execution on that
  origin — stored XSS against every user, including the superadmin panel's
  session. Only formats the app renders are accepted; `svg` is excluded because it
  is an XML document that can carry `<script>`, not an inert image. Backed by
  `nosniff` + `default-src 'none'; sandbox` on every media response.
- **Central error handler.** Unrecognized errors used to reach the client with
  their message intact; Prisma exceptions embed table names, column names and
  query fragments — a free schema map. Those are now logged server-side and
  answered with a bare `INTERNAL`.
- **Auth rate limiting.** `RATE_LIMIT_AUTH_MAX_PER_MIN` existed in config and
  `.env.example` but was never wired to a route. The per-phone cooldown only
  bounds abuse of a *single* number, so one IP could pump OTP SMS to thousands of
  different numbers — real money out of the SMS gateway, and a phone-number
  enumeration oracle. Now applied to `/auth/otp/send`, `/auth/otp/verify` and
  `/auth/refresh`.
- **Liveness vs readiness split.** `/health` is public and unthrottled, and used
  to run a DB query — anyone could drain the connection pool by hammering it. It
  is now a pure liveness check; the DB probe moved to `/health/ready`, behind the
  rate limiter, with its result cached ~2s so a burst of probes collapses into one
  query.
- **Cross-chat message disclosure via reply-to (IDOR).** `sendMessage` resolved
  the quoted message by id **alone**, then copied its text onto the new message
  and returned it to the sender. Message ids are sequential `BIGINT`s, so any
  authenticated user could sit in their own chat and walk `id=1,2,3…` to read the
  first 512 characters of *every private message in the database* — every
  customer's conversation with every store. The lookup is now scoped
  `{ id, chatId }`, and the stored `replyToMessageId` uses the validated id so a
  foreign pointer isn't persisted either. An out-of-chat id now behaves exactly
  like a deleted one: the message sends, without a quote.
  (`chat.reply-idor.test.ts`; `sharedPostId`/`sharedStoryId` were checked and are
  **not** affected — they copy no server-side content, and posts/stories are
  already readable by any authenticated user.)
- **Phone-number harvesting via `GET /users/:id`.** The phone gate was
  `role === 'admin' || 'superadmin'`, so **any** store admin could read **any**
  user's number — customers who had never contacted their store, and other
  admins. Directly harvestable, because store leaderboards are readable by every
  authenticated user and expose raw `userId`s: walk a rival store's leaderboard,
  resolve the whole list to phone numbers. Phone is the login identity in this
  system, which is what makes it worth protecting. A store admin now only sees
  the number of someone who has actually opened a chat with one of *their*
  stores (one indexed existence check) — exactly the case the chat header needs.
  Superadmin, and a user viewing themselves, are unaffected.
- **Interaction-counter inflation.** `POST /posts/interactions` accepted up to
  100000 per field across 1000 items — 100,000,000 fabricated views in one
  request — with no server-side dedup, because dedup deliberately lives
  client-side (see §6b). `interaction_buffer.dart` stores at most one row per
  `(post, kind)` per window, so an honest client sends 0 or 1 per field; the cap
  is now 1, and repeats of the same `postId` inside one batch are collapsed
  server-side (the per-item cap alone didn't stop listing a post 1000 times).
- **`GET /stories/:id/views` had no authorization** despite a comment saying it
  was for "the owning store's admin" — any authenticated user could read any
  store's reach numbers, which is competitive information. Now restricted to
  that store's admins.
- **Malformed numeric ids returned 500.** `BigInt("abc")` throws, and several
  routes fed a raw path param or cursor straight into it, so
  `/notifications/abc/read` and friends surfaced as an unhandled INTERNAL error.
  `lib/ids.ts` parses strictly (digits only — `BigInt()` itself would accept
  `" 12 "`, `"-1"`, `"0x10"`); routes answer 400, cursors fall back to page one.
- **JWT algorithm pinned to HS256.** Hardening, not a live hole: jsonwebtoken v9
  already rejects `alg:none` outright (verified empirically) and the secret is
  symmetric, so RS256→HS256 confusion doesn't apply. What an unpinned verify did
  accept is a different HMAC variant (HS512); pinning keeps the accepted-token
  set exactly equal to the issued-token set.
- **Account deletion revocation.** See §8.

### Checked and deliberately NOT changed

Recording these so a future audit doesn't re-litigate them:

- **Firebase API keys in `mobile/lib/core/firebase_options.dart`** are *not*
  secrets. Client API keys identify the project; they don't authorize anything.
  Safe to ship in the app binary.
- **`sharedPostId` / `sharedStoryId` on messages** are stored unvalidated, but
  copy no server-side content (unlike the reply-to quote, which did). The client
  refetches via `/posts/:id`, already readable by any authenticated user.
- **`activeChatId` on `PATCH /users/me`** accepts any chat id, but is only ever
  read back for the *owning* user's own push suppression, so setting a foreign
  id affects nobody else.
- **Deep `LIMIT/OFFSET` pagination** — see §6a.

## 6b. Interaction counters are client-authoritative by design

View/send/share dedup lives entirely in the mobile client
(`interaction_buffer.dart`: one row per `(post, kind)` per 30-minute window,
flushed in batches, survives offline). That was a deliberate trade for offline
batching, and it means the server cannot verify these counts — it can only bound
them, which is what the cap above does.

The consequence to be aware of: a determined caller can still add 1 per post per
request, repeatedly, bounded only by the rate limiter. These are vanity metrics
(the prize leaderboard is driven by *orders*, not views), so that was judged
acceptable. The `post_views` / `post_sent` / `post_shares` tables still exist in
the schema but are **never written** — only cleared on account deletion. They are
the leftover of the old server-side dedup and are where per-user dedup would go
if these counts ever need to be trustworthy.

## 6a. Query performance: the feed index

`/feed` — the app's home screen, and the single hottest query in the system —
filters `type IN ('image','carousel')` and orders by `createdAt`. The
`(type, createdAt)` index **cannot** serve that: it orders by `createdAt` only
*within* one type, so spanning two made MariaDB abandon the index entirely.

Measured on a 300k-post scratch database (never the live one):

| | plan | time |
|---|---|---|
| before | `ALL` — full scan of 293k rows + `Using filesort` | **135 ms** |
| after `@@index([createdAt])` | `rows: 20`, no filesort | **0.2 ms** |

~650× faster, and the old cost grew linearly with total post count. `/reels`
(single type) and `/stores/:id/posts` already used their indexes correctly and
were left alone.

**Deliberately not changed:** these endpoints use `LIMIT/OFFSET`, and a deep
offset still walks the skipped rows (~550 ms at offset 5000). Fixing that means
cursor pagination — an API change rippling into the mobile client — for a
scenario (scrolling 5000+ posts deep) that effectively never happens. Revisit
only if real traffic shows deep pagination.

## 7. Before launch (not yet done)

Honest list of what remains:

1. **Load test.** Nothing above has been verified at 100k DAU. Test WebSocket
   fan-out at expected peak concurrency and the message-send path under
   simultaneous senders in one chat (that path deadlocks on MySQL by nature and
   relies on `withRetry` — it is tested for correctness, not at load).
2. **Backup + restore drill.** Restore into a scratch database and boot against
   it. An untested backup is not a backup.
3. **Real `serviceAccount.json`** on the server for FCM, or push stays disabled.
   Confirm `git check-ignore` covers it before it lands.
4. **On-device matrix**, including the offline outbox replay loop (airplane mode →
   send → restore signal → exactly one message).
5. **Rotate `JWT_SECRET`** away from any development value. Rotating invalidates
   all access tokens; refresh tokens survive, so clients recover on their own.

## 8. Account deletion

Self-service deletion **anonymizes in place** rather than deleting the row.
Orders are a store's business records and `orders.userId` is a RESTRICT FK, so the
row survives as a tombstone with everything personal removed:

- Scrubbed: `phone` → a `del_…` sentinel, `name`, `avatarUrl`, `activeChatId`,
  plus `orders.userPhone` (a denormalized copy — leaving it would leak exactly
  what deletion is supposed to remove).
- Deleted: chats and their messages, likes/saves/views/sent/shares, story views
  and seen markers, notifications, notification requests, sessions, FCM tokens,
  and leaderboard entries (so a deleted user leaves *public* surfaces while the
  store keeps its private sales record).
- Rejected afterwards: sessions are gone so refresh dead-ends, and
  `getClaimsForUser` refuses to mint claims for a tombstone. An in-memory
  revocation set bounded by the access-token TTL closes the remaining gap on the
  no-DB fast path — a stateless JWT would otherwise keep working for up to 15
  minutes and let a "deleted" user recreate data.

Rewriting the phone frees the real number, so signing up again creates a genuinely
new account rather than resurrecting the tombstone.

Store admins and superadmins are refused (409 `STORE_OWNER_CANNOT_DELETE`): their
stores and accepted orders would cascade *other* users' data, which is a superadmin
operation rather than a self-service button.

## 8a. Order idempotency

Accepting an order is a real sale **and** increments the prize leaderboard, but
originally had no dedup of any kind. The mobile sheet has a `_submitting` flag,
which stops a naive double-tap — it does **not** stop the realistic failure: the
request succeeds server-side, the response is lost on a flaky mobile connection,
the admin sees an error and taps again. That recorded a second sale and
double-counted the customer's standings, directly corrupting prize results.

`orders.clientKey` (nullable `UNIQUE`) now mirrors the mechanism messages already
used. The client mints **one key per opened accept-sheet**, not per tap: a retry
inside that sheet collapses onto the original order, while deliberately reopening
the sheet mints a new key and creates a genuine second sale.

The order's "Order accepted ✅" chat message uses a deterministic
`order:{orderId}` key, so a retry that follows an attempt which died *between*
creating the order and posting its message still posts it exactly once — the gap
a naive early-return would have left open. Omitting `clientKey` entirely is
still accepted (older app builds), and simply behaves as before.

## 9. Superadmin panel: password login (deviation from Phase 8)

`07_MIGRATION.md` Phase 8 documents a deliberate decision: superadmin uses the
same phone-OTP flow as everyone else, with no separate password column. That
changed on 2026-07-30 **at the owner's explicit request** — the superadmin panel
now logs in with phone + password, not OTP. Mobile and every other role are
completely unaffected; the OTP endpoints still exist and still serve them.

**What this trades away**: OTP is a possession factor (you need the phone). A
password is a knowledge factor (you need to know it, and it can be guessed,
phished, or reused from a breach elsewhere) — and this guards the single most
privileged role in the system: broadcast to all users, store creation/deletion,
order visibility across every store. Treat `docs/00_PROJECT_OVERVIEW.md`-level
weight on this password; a weak one is a genuine account-takeover risk, not just
an inconvenience.

**What was still done to keep it reasonable**:

- `users.passwordHash` (bcrypt, 12 rounds) — `server/src/auth/superadminAuth.ts`.
  Null for every non-superadmin account; the mobile app never reads or writes it.
- `POST /auth/superadmin/login` (`server/src/auth/routes.ts`) returns the exact
  same `INVALID_CREDENTIALS` 401 for every rejection reason — wrong password,
  unknown phone, a real account that isn't superadmin, or a superadmin with no
  password ever set — so the response can't be used to enumerate which phone
  numbers exist or hold the role.
- The "unknown phone" path still runs one real bcrypt comparison (against a
  fixed dummy hash) before rejecting, so response timing can't leak account
  existence either — the natural next place this class of bug hides once the
  error *codes* are unified.
- Same `RATE_LIMIT_AUTH_MAX_PER_MIN` limiter as the OTP routes. This is now the
  one password-guessable surface in the system; it needs the limiter more than
  OTP does, not less.
- On success it mints the exact same access/refresh token pair `otp/verify`
  does, through the same `createSession` — nothing downstream (claims,
  `requireFreshAuth`, revocation on account deletion) needed to change.

**Before this ships to real users**: rotate the seeded password
(`semayadmin` — set for one account, `+99363538839`, during initial setup) to
something you wouldn't find in a breach-compilation wordlist, and consider
whether the superadmin role needs a second factor given what a compromise here
can do. There is currently no "change my password" self-service route — a new
password can only be set the way this one was, directly against the database.
