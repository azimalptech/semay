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
| 6 | **Load-test before launch** | Everything above is necessary but not sufficient. **Done — see §7**, which found two defects (deadlocks on the like/message paths, and requirement 3 above being violated in the live `.env`) that no amount of review had surfaced. | `server/scripts/loadtest.mjs` |

### Sizing starting point

For one 8-core / 16 GB server:

```ini
CLUSTER_WORKERS=0                 # one per core
DATABASE_URL="mysql://…/semay?connection_limit=15&pool_timeout=20"
REDIS_URL="redis://127.0.0.1:6379"
```

8 workers × 15 connections = 120, comfortably under MySQL's 151 default. If you
raise `max_connections`, raise `connection_limit` with it — not before.

`cluster.ts` checks this arithmetic against the server's real `max_connections`
at boot and refuses to start if it does not fit, because getting it wrong does
not fail cleanly — it fails as scattered 500s under load, with nothing in the
logs pointing at the cause (§7).

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

### 3a. Liveness: why chat used to go quiet, and what keeps it alive now

A phone's connection dies without saying so — carrier NAT resets, Doze, a
Wi-Fi→LTE handover, iOS suspending the process. The first version of the
realtime path assumed a socket that was open was working, and had four separate
ways of silently stopping until the app was restarted. Each one is a real
report of "messages don't arrive", and each has a specific fix:

| Failure | Fix | Where |
|---|---|---|
| Half-open socket looks connected forever; nothing arrives | Heartbeats both ways: the app pings every 20 s (dart:io `pingInterval`, closes on a missed pong); the server pings every 30 s and `terminate()`s a peer that misses a whole interval | `realtime_client.dart`, `gateway.ts` |
| Reconnect after 15 min reused the expired access token → server `4401` → retry every 2 s with the same dead token, forever | A fresh token is obtained *before* every connect (`AccessTokenSource.validToken`, refreshing when < 60 s remain); a `4401` close forces a refresh on the next attempt | `api_client.dart`, `realtime_client.dart` |
| A connect that threw never scheduled a retry | Exponential backoff with ±50 % jitter (1 s → 30 s); a connection that lived ≥ 5 s resets it so the first retry after a real drop is immediate | `realtime_client.dart` |
| Nothing reconnected on app resume, network change, or login/logout | On resume/online: an application-level `{type:"ping"}` with a 5 s deadline, reconnect on silence. On session change: new socket (the old one authenticated as the old user) | `main.dart`, `realtime_client.dart`, `gateway.ts` |

Related fixes in the same pass:

- **Concurrent token refresh** is single-flight. The REST interceptor and the
  socket can both notice an expired token in the same instant; the server
  rotates the refresh token on every call, so the second refresh presented an
  already-revoked token and the session was killed for nothing. The interceptor
  also no longer logs out when the refresh endpoint was merely *unreachable* —
  only when it *rejected* the token.
- **Receipts are a roll-up event**, not a re-snapshot. `markReceipts` published
  the full 200-message window on every delivered/read receipt; with delivered
  receipts now firing per incoming message, that was up to ~2×200 messages of
  JSON per message sent, to every subscriber. It now publishes
  `{type:"receipts", data:{senderRole,status,at}}` and the client stamps the
  matching messages itself.
- **Sent messages no longer depend on the socket** to appear. The outbox hands
  the POST response straight to the open thread; the socket echo is a harmless
  overwrite. Previously a send while the socket was down made the optimistic
  bubble vanish (the outbox item was done) with nothing replacing it.
- **The outbox retries on its own** (2 s, 4 s, 8 s, 16 s, then ~30 s) instead of
  waiting for a connectivity change or the next send, and the shared Dio has
  receive/send timeouts so one hung request cannot wedge the queue forever. A
  trigger that lands mid-drain is remembered and honoured when the drain
  settles; the queue is emptied on logout and never drains without a session
  (rows from the previous user must not go out under the next one).
- **Frames are hostile input.** A client text frame of exactly `null` parsed
  successfully and the first property access threw synchronously inside ws's
  receiver — an uncaught exception, i.e. any authenticated user could stop the
  process with four bytes (pre-existing; found by the review of this pass).
  The gateway now rejects non-object frames, wraps the handler, and caps frames
  at 4 KiB (`maxPayload`; ws's default is 100 MiB). Subscribe bookkeeping keys
  on a per-attempt placeholder so a subscribe/unsubscribe/subscribe burst can't
  install two bus listeners. The access token no longer reaches the disk log
  (request serializer redacts `token=` in URLs).
- **A refresh is "rejected" only on 400/401/403.** A 429 from the auth rate
  limiter (60/min per IP, and carrier NAT puts many phones behind one IP) or
  a 5xx used to count as rejection and log the user out; now it is
  "unreachable" — retried, session kept. A logout that completes while a
  refresh is in flight also wins over that refresh.

### 3b. Push: what the server sends and why

- **No server-side suppression.** `users.activeChatId` used to skip both the
  push and the unread increment when it matched the chat. The flag is written by
  the app on enter/leave; a killed app, a crash, or a PATCH lost to bad signal
  left it stuck, and that chat then never badged or notified its user again.
  Whether someone is looking at a thread is only knowable on their device, so
  the app suppresses its own in-app banner and the server counts and pushes
  regardless. The thread screen answers each incoming message with a read
  receipt within one round-trip, so the counter is back at 0 before anyone sees
  it. The column is kept as a diagnostic hint only.
- **Payload** (`notifications/push.ts`): `android.priority=high` (wakes a dozing
  device), `channelId=chat_messages` (a channel the app creates at
  IMPORTANCE_HIGH — heads-up banner + sound; FCM's default "Miscellaneous"
  channel is silent), `tag=<chatId>` (one notification per conversation, newest
  replaces oldest; iOS `thread-id` groups them), `contentAvailable` (iOS wakes
  the app to post the delivered receipt), and `data:{type,chatId,messageId,
  senderRole}` — `chatId` is what a notification tap routes to.
- **Launcher badge** is per recipient: `SUM(unreadByUser)` across the user's
  chats, or for an admin the sum across every store they manage (two queries
  however many admins) — muted chats excluded, because a muted chat sends no
  push and counting it would make the icon lag and then jump on an unrelated
  read. `content-available` (the background wake-up for the delivered receipt)
  is opt-in per push and only chat messages set it; a broadcast or an order
  notice has nothing for the app to do in the background. After a read receipt an iOS-only badge-only push
  corrects the number back down; Android launchers count the notifications
  themselves. Badge work is skipped entirely when FCM is not configured.
- **iOS needs three things or push never arrives**, and the app otherwise runs
  fine so this is easy to miss: `aps-environment` in `Runner.entitlements`
  (now in the Xcode project), `UIBackgroundModes: remote-notification` in
  Info.plist (now set), and an APNs key uploaded to the Firebase project with
  the App ID's Push Notifications capability enabled (portal work, not code).

## 4. Logging

Newline-delimited JSON to `LOG_DIR/app.<date>.log`, rotated daily and pruned to
`LOG_RETENTION_DAYS` files (default 14) so disk use is bounded. Console output is
pretty-printed outside production only. `LOG_LEVEL` controls verbosity.

Boot logs two things worth alerting on:

- `FCM push is DISABLED` — the service-account file is missing, unreadable, not
  a service-account key, or belongs to a different Firebase project than
  `FIREBASE_PROJECT_ID` (the reason names both ids), so no push will be
  delivered. The API otherwise runs normally by design. Its counterpart,
  `FCM push enabled`, logs the project and sender email so they can be checked
  against the app's `firebase_options.dart` (`09_DEPLOYMENT.md` §5d).
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

## 7. Load test results (measured 2026-08-06)

Harness: `server/scripts/loadtest.mjs` (`npm run loadtest`). It drives the real
HTTP and WebSocket surface — Fastify, auth middleware, Prisma, MySQL, the Redis
bus — not a synthetic query benchmark, and removes everything it creates,
including on Ctrl-C.

Run against a **scratch MySQL instance on port 3307** restored from a production
dump, never the live database. 8 cluster workers, `connection_limit=15`,
200,001 posts, on a 16-core / 34 GB Windows machine where the client harness,
both MySQL instances and the API all shared the same CPU. **Real numbers on
dedicated hardware would be higher, not lower.**

### Two defects the load test found (both fixed)

Neither was visible to code review, the test suite, or single-process use. Both
only appear under concurrency, which is exactly why this step existed.

**1. Lock-upgrade deadlocks on the two hottest write paths.** Liking a post
inserts a `post_likes` row and then increments `posts.likesCount`. Because
`post_likes.postId` is a foreign key, the INSERT takes a **shared** lock on the
parent `posts` row and the UPDATE immediately after needs that same row
**exclusively** — so two concurrent likes each held S, each waited to upgrade to
X, and InnoDB broke the tie by rolling one back. Confirmed against MySQL's own
`LATEST DETECTED DEADLOCK` report, not inferred from the stack trace.

- `POST /posts/:id/like` failed **7.5% of requests (225 of 3,000)** with HTTP
  500 at 50 concurrent likes on one post. `setToggle` had no retry wrapper at
  all, so every deadlock reached the user.
- `POST /chats/:id/messages` failed 2 of 3,000. It *does* use `withRetry`, but
  8 attempts were exhausted under sustained same-chat contention.

Fixed by taking the exclusive lock up front (`SELECT … FOR UPDATE`) before the
INSERT, in a consistent order — post, then store — which turns the deadlock into
an ordinary queue. Applied to `setToggle`, `createPost`, `deletePostCascade`
(`posts/service.ts`) and `sendMessage` (`chats/service.ts`); `setToggle` also
gained the `withRetry` it was missing. Pinned by
`server/tests/like.concurrency.test.ts`, which asserts on InnoDB's
`Innodb_deadlocks` counter — verified to fail when the fix is reverted.

**2. Connection-pool exhaustion (requirement 3 in §2, violated in practice).**
The live `.env` had no `connection_limit`, so each worker took Prisma's default
of `cores × 2 + 1` = 33. Eight workers wanted 264 connections against MariaDB's
stock `max_connections=151`; `Max_used_connections` topped out at exactly 152 and
requests failed with *"Too many database connections opened"*. Fixed in `.env`,
and `cluster.ts` now **refuses to boot** when `workers × connection_limit + 40
reserved` exceeds the server's actual `max_connections`, printing the three ways
to fix it. A server that starts and then fails a fraction of requests is worse
than one that refuses to start.

### Throughput (8 workers, tuned MySQL, zero failed requests)

| Scenario | conc | req/s | p50 | p95 | p99 |
|---|---|---|---|---|---|
| `GET /feed` page 1 | 1 | 289 | 3.1 ms | 5.7 ms | 6.8 ms |
| `GET /feed` page 1 | 10 | 1,882 | 5.0 ms | 7.3 ms | 11.9 ms |
| `GET /feed` page 1 | 100 | 2,270 | 39.9 ms | 71.8 ms | 160.1 ms |
| `GET /feed` offset 500 | 50 | 1,356 | 33.3 ms | 66.0 ms | 118.3 ms |
| `GET /reels` | 50 | 2,379 | 14.0 ms | 58.5 ms | 138.4 ms |
| `GET /stores` | 50 | 4,220 | 10.6 ms | 18.2 ms | 26.4 ms |
| `GET /chats` (user) | 50 | 4,396 | 10.8 ms | 18.2 ms | 20.0 ms |
| `GET /chats/:id/messages` | 50 | 3,142 | 15.3 ms | 22.8 ms | 26.9 ms |
| `POST` message | 50 | 1,156 | 41.9 ms | 67.2 ms | 91.4 ms |
| `POST` interactions flush | 50 | 1,601 | 29.3 ms | 50.2 ms | 64.1 ms |
| like/unlike, **one** post | 50 | 794 | 58.4 ms | 106.6 ms | 124.1 ms |
| like/unlike, spread | 50 | 829 | 45.0 ms | 97.2 ms | 101.8 ms |

42,000 HTTP requests, **zero non-2xx responses**.

The single-post like figure is the deliberate worst case: 50 clients contending
for one row. 794/s on one post is the floor, and it is ~250× a realistic viral
peak.

### WebSocket capacity

**12,000 concurrent sessions on one machine, all live, zero dropped** — every
socket connected, subscribed, and received its snapshot. Measured single-process
and again in cluster mode.

- Memory: **~54 KB per connection** (RSS 167.6 MB idle → 800.5 MB at 12,000).
- Handles returned to baseline (371 → 12,370 → 369) and RSS did not grow across
  three successive storms, so sockets and their memory are fully reclaimed —
  **no leak**.
- Fan-out (publish → subscriber receives) stayed at **7–13 ms** with 12,000
  sockets connected.
- 12,000 was the **client's** ceiling, not the server's: Windows' ephemeral port
  range (13,977) ran out, and a repeat run failed with `EADDRINUSE ×10,221`
  while TIME_WAIT drained. The server never refused a connection.

### What this means for 100k DAU

100k DAU is roughly 5–10k concurrent at peak on a consumer app. Against that:

- **Sockets: comfortable.** 12,000 verified on one box against a 5–10k peak,
  with ~54 KB each (a 10k peak ≈ 540 MB).
- **Read throughput: comfortable.** ~2,300 feed req/s ≈ 8.3M feed loads/hour.
- **Writes: comfortable.** ~1,150 messages/s and ~800 likes/s *on a single
  contended row*; spread across rows there is far more headroom.
- **The binding constraint is shared, not per-worker.** Measured on the same
  database and dataset, going from 1 worker to 8 bought only ~1.4× throughput,
  fairly uniformly: `/feed` at concurrency 100 went 1,533 → 2,143 req/s,
  `/stores` 2,927 → 3,877, `/chats` 3,082 → 4,123. Eight times the CPU for 1.4×
  the work means the ceiling is behind the workers — MySQL, and to some degree
  the single test machine hosting everything at once. Adding workers past this
  point will not help; a read replica, a cached first feed page, or moving MySQL
  to its own host would.

  This is a ratio measured under artificial conditions (harness, API and two
  MySQL instances all on 16 shared cores). Treat the *shape* as the finding —
  scaling is DB-bound — and re-measure on real hardware before sizing to it.

### MySQL configuration

XAMPP's stock `innodb_buffer_pool_size=16M` on a 34 GB machine was the largest
single misconfiguration. Changed in `C:/xampp/mysql/bin/my.ini`
(original preserved as `my.ini.bak-20260806`):

| Setting | Was | Now | Why |
|---|---|---|---|
| `innodb_buffer_pool_size` | 16M | 4G | Caches data **and** indexes; at 16M nearly every feed query reads from disk |
| `innodb_log_file_size` | 5M | 512M | 5M forces a checkpoint flush every few hundred writes |
| `innodb_log_buffer_size` | 8M | 32M | Matches the larger log |
| `max_connections` | 151 | 500 | The ceiling the cluster actually hit |
| `innodb_io_capacity` | 200 | 2000 | Data directory is on the SSD (verified) |
| `innodb_flush_neighbors` | 1 | 0 | A rotational-disk optimisation; only costs writes on flash |
| `innodb_flush_log_at_trx_commit` | 1 | **1 (unchanged)** | 2 is measurably faster but risks losing a second of committed transactions. This database holds orders. Do not "optimise" this. |

Measured effect at 89 MB of data: **+5% to +31%** throughput (`/stores` +31%,
`POST` message +24%, `/feed` +7%) and materially better tails (`/feed` offset 500
p99 158.8 ms → 71.2 ms). The gain is modest here only because 89 MB largely fits
in cache either way; it grows with the dataset, which is the point.

> **These changes are written to `my.ini` but are NOT yet active** — applying
> them needs a MySQL restart, which needs an elevated shell. Run
> `net stop mysql && net start mysql` as Administrator, then confirm with
> `SELECT @@innodb_buffer_pool_size, @@max_connections;`.
>
> The redo-log resize was rehearsed on a scratch instance first, including a
> **hard kill** to simulate power loss: MariaDB 10.4.32 resized the log on the
> next start in both the clean and unclean case, with data intact. It is safe.

### Reproducing

```bash
# Never point this at the live database.
node --env-file=.env scripts/loadtest.mjs \
  --api http://127.0.0.1:8099/api/v1 \
  --posts 200000 --requests 3000 --sockets 12000
```

`--skip-http` isolates socket capacity; `--hold 30` keeps the pool open so RSS
can be sampled while the connections are actually held.

## 7a. Backup and restore

`server/scripts/backup.mjs` (`npm run backup`, `npm run backup:verify`).

- `--single-transaction`, gzipped, timestamped, keeps the last 14 (`BACKUP_KEEP`).
- Connection details come from `DATABASE_URL`, so the backup follows the app if
  it is ever repointed. The password goes through `MYSQL_PWD`, never argv, where
  any other user could read it from the process list.
- `--verify` restores the dump it just took into a scratch schema, compares
  **every table's row count plus the foreign-key and index totals** against the
  live database, then drops the scratch schema. Row counts alone would pass a
  restore that silently dropped every foreign key.
- `--verify --file <path>` verifies an existing backup without taking a new one.
- Exit code is 1 on failure, so a scheduled task notices.

Drill performed 2026-08-06: dump → restore → **25 tables, 34 foreign keys, 87
indexes, all row counts matching**. Verified in both directions — a deliberately
truncated dump was correctly rejected with a non-zero exit and left no scratch
schema behind.

Schedule it (Task Scheduler, daily) and keep at least one copy off this machine.
A backup on the same disk as the database is not a backup.

## 7b. Before launch (still outstanding)

1. **Restart MySQL and the API**, both from an Administrator shell. The MySQL
   tuning in §7 is written to `my.ini` but inert until a restart, and the running
   `SeMay API` service still holds the pre-fix build in memory — the deadlock
   fixes are compiled into `dist/` but a Node process does not reload modules.

   ```bat
   net stop mysql  && net start mysql
   net stop "semayapi.exe" && net start "semayapi.exe"
   ```

   Then confirm both took effect:

   ```bat
   mysql -u root -e "SELECT @@innodb_buffer_pool_size, @@max_connections;"
   curl http://127.0.0.1:8080/health/ready
   ```

   Neither is urgent at current traffic — the deadlocks need ~50 concurrent
   writers on one row to appear — but both should be done before real load.
2. **Real `serviceAccount.json`** on the server for FCM, or push stays disabled.
   Confirm `git check-ignore` covers it before it lands.
3. **On-device matrix**, including the offline outbox replay loop (airplane mode →
   send → restore signal → exactly one message).
4. **Rotate `JWT_SECRET`** away from the development value, and change the
   superadmin password. Rotating the secret invalidates all access tokens;
   refresh tokens survive, so clients recover on their own.
5. **Schedule the backup** as a task, and copy backups off this machine.
6. **Run our own SMS relay** (`sms-gateway/`, deploy steps in
   `09_DEPLOYMENT.md` §5b). This item has now been wrong twice, and both
   corrections are worth keeping because the reasoning generalises.

   It first said to fix OTP delivery with a static DHCP reservation for the
   phone at `192.168.100.74`. That held only while the API shared a LAN with
   the phone; once the API moved to a hosted box, `192.168.100.74` became a
   private address behind NAT with no route from the server, and a reservation
   would have kept it stable and still unreachable.

   It then said to use capcom6's **Cloud server** mode
   (`https://api.sms-gate.app/3rdparty/v1`), on the reasoning that an outbound
   connection from the phone sidesteps NAT entirely. Sound reasoning, wrong
   conclusion: that host is unreachable from Turkmen networks. Measured from
   the gateway handset, on the same Wi-Fi, at the same moment — 100% packet
   loss to `api.sms-gate.app`, 0% to `google.com`, `fcm.googleapis.com` and
   `semaycollection.com`. Messages were accepted by the relay's API and then
   sat at `Pending` forever, because the phone could never collect them.

   The lesson under both: **reachability is a property of the specific pair of
   endpoints**, and it has to be measured from the device that will actually
   make the connection, not inferred from topology. Our own relay is on a host
   the handset demonstrably reaches (13ms), and it runs two transports — a
   WebSocket, and HTTP long-polling for when that is severed — so a proxy or
   NAT that kills one does not take OTP down.

   The old gateway app also advertised a public IPv6 address for Local Server
   mode. Don't use that either: it exposes an SMS-sending endpoint to the whole
   internet behind only HTTP Basic auth, and the address is not stable.

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

**Before this ships to real users**: rotate the password seeded during initial
setup for the single superadmin account. The seeded value is a short dictionary
word and is **not** recorded here on purpose — a repository that documents its
own admin credential has handed it to anyone who reads the repository. Replace
it with something you would not find in a breach-compilation wordlist, and
consider whether the superadmin role needs a second factor given what a
compromise here can do.

Rotate it through `POST /auth/superadmin/change-password`, which requires the
current password (an access token alone is not enough), enforces a 12-character
minimum, and deletes every existing session so a leaked token cannot outlive the
change. Covered by `server/tests/superadmin.change-password.test.ts`.
