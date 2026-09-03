# 07 — Firebase → Self-Hosted MySQL Migration

> **Operational state lives in [`08_OPERATIONS.md`](./08_OPERATIONS.md).** This file is the
> phase-by-phase history of the migration. Everything about running the result — topology, the
> requirements for 100k daily active users, the scheduled reaper, and the security hardening pass
> (media upload allowlist, error-message leakage, auth rate limiting, account deletion) — is there.
> Read 08 before deploying or changing auth/media/realtime.

**Status: IN PROGRESS (Phase 9 done; 9b offline outbox + Phase 10 staging/cutover remain).** Full
architecture + rationale: the approved plan at
`.claude/plans/iterative-launching-meteor.md`. This doc is the living, in-repo reference kept
alongside the code as each phase lands.

## Why

Data sovereignty: all user data (Turkmen phone numbers, chats, orders) must live on infrastructure
the owner fully controls, **physically hosted in Turkmenistan**. Full migration off Firebase
(Firestore, Auth, Storage, Cloud Functions) — keeping **only FCM** for push. All current Firebase
data is disposable test data, so there is **no production data migration**: the new backend starts
empty and cutover is "point the app at the new server."

## New components

- **`server/`** — the new self-hosted API (Node.js + TypeScript, Fastify + `ws`, Prisma → MySQL 8,
  a local public media folder, Firebase Admin SDK for FCM send only). Replaces the old Firebase Cloud
  Functions and Firestore/Auth/Storage.
- **`backend/`** — the OLD Firebase Cloud Functions. **Deleted** (2026-07-30, at the owner's explicit
  request) once nothing in the running stack or CI referenced it. `docs/03_CLOUD_FUNCTIONS_API.md` is
  now the only remaining record of those contracts.
- **`mobile/`** / **`web-admin/`** — rewritten in Phases 9 / 8 to consume the new API; provider
  names/signatures kept stable so screens change minimally.

## Phase status

| Phase | What                                                                      | Status                  |
| ----- | ------------------------------------------------------------------------- | ----------------------- |
| 0     | **Owner:** provision TM server (MySQL 8, TLS, Node, disk for media, backups) | ⬜ owner task        |
| 1     | Server scaffold + Prisma schema (`server/prisma/schema.prisma`)           | ✅                      |
| 2     | Auth (OTP, sessions, JWT fast/slow, phone-UNIQUE race) + concurrency test | ✅                      |
| 3     | Core CRUD + storage + authz middleware + per-route/role test matrix       | ✅                      |
| 4     | Real-time WebSocket gateway (channel pub-sub, snapshot-then-diff)         | ✅                      |
| 5     | Chat (list-diff channels, messages, receipts/typing/mute/hide)            | ✅                      |
| 6     | Orders, leaderboard, notifications, quick replies, requests, broadcast    | ✅                      |
| 7     | Relocate FCM sender; repoint token registration + delivery receipts       | ✅                      |
| 8     | Web-admin rewrite (2-tier session, Prisma Server Components)              | ✅                      |
| 9     | Mobile rewrite (REST/WS client across all providers + screens)            | ✅ (9b outbox deferred) |
| 9b    | Offline SQLite outbox + read-side cache                                   | ⬜ deferred             |
| 10    | Staging rehearsal, two-device test, cutover                               | ⬜                      |

## Schema: notable relational changes from Firestore

Field-for-field the schema mirrors `docs/02_DATA_MODEL.md`; these are the deliberate structural
differences (all documented inline in `server/prisma/schema.prisma`):

- **`store_admins` junction table** replaces BOTH `stores.adminIds` and `users.storeIds` arrays —
  the old hand-maintained dual-write drift bug is designed out. `role` stays a column on `users`.
- **`users.id` is a random UUID again** (not sha256(phone)). The `phone UNIQUE` constraint IS the
  "1 phone = 1 account" lock now — a plain INSERT that hits duplicate-key (MySQL 1062) makes the
  loser re-SELECT the winner's row. This is the SQL-native fix for the race the deterministic-uid
  trick worked around under Firestore.
- **`post_media`** replaces `posts.mediaUrls[]` (real `position` ordering column + deletable rows).
- **`post_likes/saves/views/sent/shares`** each replace an existence-checked subcollection. The old
  `users/{uid}/liked` and `users/{uid}/saved` mirror collections are **dropped** — `INDEX(userId,
createdAt)` on `post_likes`/`post_saves` serves "My Liked/Saved" directly.
- **`chats.id` keeps the deterministic `${userId}_${storeId}` PK** — `createOrGetChat` becomes an
  `INSERT IGNORE` in a synchronous transaction, so the Firestore `!hasPendingWrites` race workaround
  is structurally impossible (no client write-cache in MySQL).
- **`messages.id` is an AUTO_INCREMENT BIGINT** — monotonic ordering replaces `orderBy(createdAt)
.limitToLast(200)`.
- **`user_fcm_tokens.token` is UNIQUE** — upsert-on-conflict fixes the reinstall/relogin token
  ownership ambiguity `arrayUnion` had.
- **`price DECIMAL(10,2)`**, **`orders.status ENUM('accepted')`**, **`user_notifications.read_at`**
  (nullable timestamp instead of a boolean) — SQL makes explicit what Firestore left loose.
- **Authorization** has no rules-file equivalent — every `firestore.rules` check becomes hand-written
  API middleware (Phase 3), covered by a per-route × per-role test matrix.

## Auth (Phase 2 — done)

`server/src/auth/`: `POST /api/v1/auth/otp/send`, `/otp/verify`, `/refresh`, `/logout`.

- `otpStore.ts` — cooldown/lockout/expiry against `otp_codes`; `verifyOtp` uses `SELECT … FOR UPDATE`
  so concurrent attempts against the same phone serialize instead of racing the attempts counter.
- `users.ts` — `findOrCreateUserByPhone`: plain `INSERT`, re-SELECT on MySQL 1062 (Prisma P2002).
  Verified with a concurrency regression test (`tests/auth.concurrency.test.ts`, 20 parallel calls
  for one brand-new phone → exactly one `users` row) — this is the test the plan called out as
  highest-value, and it passes against real local MySQL.
- `session.ts` — refresh tokens are opaque, stored **hashed** in `sessions`; `rotateSession` revokes
  the old row and issues a new one on every `/refresh` call, so a replayed old token dead-ends
  (verified live: reusing a rotated-away token returns `401 SESSION_INVALID`).
- `middleware.ts` — `requireAuth` (fast, local JWT verify) and `requireFreshAuth` (slow, re-derives
  claims from the DB and rejects a stale `claimsVersion` with `CLAIMS_STALE`). No route uses
  `requireFreshAuth` yet — it's consumed starting Phase 3's authz middleware.
- `sms.ts` — `SmsProvider` interface; dev-mode logs instead of sending (`OTP_DEV_MODE=true`, matches
  local `.env`), gateway implementation talks to the same capcom6/android-sms-gateway HTTP API as
  the old Cloud Functions.

## Phase 3 progress — users & stores (done so far)

`server/src/users/routes.ts`: `GET/PATCH /api/v1/users/me` (self profile — name, avatarUrl,
language, darkMode, activeChatId).

`server/src/stores/`: `GET /stores`, `GET /stores/:id` (any authenticated user — public read, matches
the old rules), `POST /stores` / `POST /stores/:id/admins` / `DELETE /stores/:id` (superadmin-only,
gated by `requireFreshAuth` + `requireRole("superadmin")` from `src/auth/authz.ts`).

- `stores/service.ts` — `setStoreAdmin`/`deleteStoreCascade` hold the transactional side effects FK
  cascades can't express: revoking down to zero managed stores (or a store being deleted out from
  under an admin) demotes `role` back to `'user'`, and `claims_version` is always bumped so the
  affected user's next request/refresh sees it. FK `ON DELETE CASCADE` handles the rest of
  `deleteStore`'s fan-out (posts, stories, chats, orders, leaderboard, quick replies, notification
  requests, store_admins) automatically — no hand-written cascade code needed, unlike the old
  Cloud Function.
- Verified live end-to-end against local MySQL: create store → grant admin (user's role flips to
  `admin`, `claims_version` bumps) → delete store (store gone, `GET` 404, admin auto-demoted back to
  `user`, `claims_version` bumps again). A plain `user` hitting `POST /stores` gets `403 FORBIDDEN`.

## Phase 3 progress — posts, stories, media (done so far)

`server/src/posts/`: `POST /stores/:storeId/posts` (store-admin), `GET /stores/:storeId/posts`,
`GET /feed` (image+carousel), `GET /reels`, `GET /posts/:id`, `DELETE /posts/:id` (owner store-admin
or superadmin — ownership resolved server-side since the route has no storeId param), and
`POST`/`DELETE` on `/posts/:id/like` and `/save`, plus create-only `POST /posts/:id/view|sent|share`.

- `posts/service.ts` — `createPost`/`deletePostCascade` keep `store.postsCount`/`reelsCount` in sync
  in the same transaction (replaces `onPostCreated`/`onPostDeleted`). Like/save toggle and
  view/sent/share counters all use "insert, ignore duplicate-key (P2002), only touch the count column
  when a row was actually inserted/deleted" — repeat calls are provably idempotent (replaces
  `onLikeWrite`/`onSavedWrite`/`onViewCreated`/`onSentCreated`/`onShareCreated`).
- `server/src/stories/`: `POST /stores/:storeId/stories`, `GET /stories/active`,
  `GET /stores/:storeId/stories`, `DELETE /stories/:id`, `POST /stories/:id/view` (records the view
  create-only AND upserts `user_story_seen` — replaces `users/{uid}/storySeen`).
- `server/src/media/`: MinIO client (`minio.ts`) + `POST /media/upload-url` (any admin) returns a
  5-minute presigned PUT URL and the eventual public URL; the client PUTs bytes directly to MinIO,
  then passes that public URL when creating the post/story. Bucket is created (idempotently) and set
  public-read at boot via `ensureMediaBucket()`.
- Verified live end-to-end: presigned PUT → object publicly GET-able → post created referencing it →
  like/save/view/sent/share all idempotent on repeat → unlike/unsave decrement correctly → delete
  cascades media/likes/etc and decrements `postsCount` → story create/list-active/view/delete all
  round-tripped against real local MySQL + MinIO.
- Along the way: fixed a real bug — `BigInt` columns (`post_media.id`, `messages.id`, etc.) have no
  native JSON representation and crashed every response containing one (`db.ts`'s global
  `BigInt.prototype.toJSON` fix, stringifies rather than `Number()`s since these can exceed
  `MAX_SAFE_INTEGER`). Also caught `CLAIMS_STALE` firing correctly live: granting yourself store-admin
  bumps your own `claims_version`, so your own now-stale access token is rejected on the very next
  admin-only call until you re-auth — exactly the self-heal the plan called for.
- `server/src/app.ts` — split `buildApp()` out of `index.ts` so tests exercise the real route tree via
  Fastify's `inject()` (no TCP listener) against the real local MySQL, instead of curl-scripting a
  running process. `index.ts` is now just `buildApp()` + `ensureMediaBucket()` + `listen()`.
- `tests/authz.matrix.test.ts` (28 cases) — the per-route × per-role matrix: for every superadmin-only,
  store-admin-only, and admin-or-superadmin route, asserts plain user / wrong-store admin / correct
  admin / superadmin / unauthenticated all get the exact status code the old `firestore.rules` would
  have produced. Signs tokens straight from real DB claims (`tests/helpers.ts`), so it exercises the
  same `signAccessToken`/`verifyAccessToken`/`requireFreshAuth` path production uses.
- Two more real bugs caught building this suite: (1) the `.env` inline-comment-stripping gap in the
  vitest env loader (`ACCESS_TOKEN_TTL_SECONDS=900   # 15 min` was being coerced to `NaN` since only
  full-line comments were skipped); (2) `setStoreAdmin` unconditionally bumps the target user's
  `claims_version` even on a no-op revoke (someone with zero store_admins rows revoked again) — not a
  bug per se, but strong enough a side effect that it staled a token mid-test-suite and had to be
  designed around (dedicated throwaway user for that case) rather than silently ignored.

**Phase 3 core CRUD is now feature-complete and verified** (users, stores/store_admins, posts+media+
likes/saves/views/sent/shares, stories, MinIO media upload, authz middleware, 28-case test matrix).
Remaining before Phase 3 fully closes: none — orders/leaderboard/notifications/quick-replies were
always scoped to Phase 6, not Phase 3.

## Phase 4 — real-time WebSocket gateway (done)

`server/src/realtime/`:

- `bus.ts` — the `publish(channel, event)` / `subscribe(channel, listener)` seam from the plan, backed
  by a plain in-process `EventEmitter` for v1. Every call site only ever imports this file, never the
  emitter directly, so a later Redis swap is one file.
- `gateway.ts` — `GET /api/v1/ws` (`@fastify/websocket`). Auth is a `?token=` query param carrying the
  same access JWT the REST API uses (verified with the same `verifyAccessToken`); an invalid/missing
  token closes the socket immediately with code 4401. Client frames are `{type:"subscribe"|
"unsubscribe", channel}`; on subscribe the server immediately sends a `snapshot` frame (current
  state, via a per-channel-prefix `snapshotProviders` registry — just `post` for now) before any live
  `upsert`/`remove` diffs, reproducing "first emission is current state" the way a Firestore listener
  did. Each connection re-checks its cached `claims_version` against the DB every 30s and force-closes
  (4401) on mismatch — the WS equivalent of `requireFreshAuth`'s `CLAIMS_STALE`, since a socket has no
  natural "next request" to piggyback the check on.
- Wired into the **simplest surface first**, per the plan: `posts/service.ts`'s like/save toggle and
  view/sent/share counters now `publish("post:{id}", {type:"upsert", data: freshCounts})` _after_ their
  transaction commits (never from inside it — a subscriber must never see an event for a write that
  could still roll back), and only when the counter actually changed (a duplicate like/view is still a
  provably-idempotent no-op with zero pub-sub noise).
- Verified live with a real `ws` client: connect → `snapshot` frame with current counts → HTTP
  like/save/unlike from a second connection → matching `upsert` frames arrive in real time with the
  post's actual updated counts, in order.
- Not yet built: list-shaped channels (`user:{uid}:chats` upsert/remove diffs) — explicitly deferred to
  Phase 5, which needs them for the chat list. Load-testing at expected peak connection count is a
  Phase 10 (staging rehearsal) concern, not blocking here.

## Phase 5 — chat (done)

`server/src/chats/`: `POST /chats` (create-or-get, user role only), `GET /chats` (own chats for a
user; `?storeId=` for an admin/superadmin), `GET /chats/:id`, `GET /chats/:id/messages`
(`?before=&limit=`, newest-first, mirrors the old `limitToLast(200)`), `POST /chats/:id/messages`,
`POST /chats/:id/receipts` (`{status:"delivered"|"read"}`), `POST /chats/:id/typing`,
`POST /chats/:id/mute`, `DELETE /chats/:id` (soft-hide for the caller's side only).

- `chats/service.ts` — `resolveChatSide`/`getChatForParticipant` is the shared authorization check
  every route runs (participant = the chat's own user, an admin of its store, or superadmin).
  `sendMessage` updates the message + the chat's denormalized `lastMessageText`/`lastMessageAt`/
  unread counters in one transaction (replaces the old async `onMessageCreated` trigger), then
  publishes to `chat:{id}:messages`, `chat:{id}`, `user:{userId}:chats`, and `store:{storeId}:chats`
  — the last two are the **list-diff channels** the plan called out as the one piece Firestore gave
  for free that had to be hand-written.
- `hideChat` is per-side and reversible by construction: `listUserChats`/`listStoreChats` filter a hidden
  chat back in the instant its `lastMessageAt` moves past the hide timestamp — no explicit "unhide"
  action needed, matching the swipe-to-delete-isn't-permanent behavior already in the mobile app.
- `realtime/channels.ts` — extended the Phase 4 gateway with a **pattern + per-channel authorize**
  registry (`post:{id}` public; `chat:{id}`, `chat:{id}:messages`, `user:{uid}:chats`,
  `store:{storeId}:chats` all check real participancy against the DB before allowing subscribe —
  never trusting the connection's cached claims for this, since those can be stale for the token's
  full 15-minute TTL). Verified live: a stranger token subscribing to another user's chat/list channel
  gets `{type:"error", error:"FORBIDDEN"}`; a participant gets `snapshot` then live `upsert` frames
  across all four channels in real time when a message is sent from the _other_ side.
- **The plan's highest-value chat test** — `tests/chat.race.test.ts`: 20 concurrent
  `createOrGetChat` + `sendMessage` calls for one brand-new user+store never fail, produce exactly one
  `chats` row, and exactly 20 `messages` rows. This caught two real bugs before they ever reached
  production traffic:
  1. `prisma.chat.upsert()` is not atomic enough under heavy first-time-creation concurrency on MySQL
     — it threw raw `PRIMARY` unique-constraint errors. Fixed by switching to the same
     insert-then-re-select-on-P2002 idiom `findOrCreateUserByPhone` already used.
  2. Many transactions racing to `UPDATE chats SET lastMessageAt=… WHERE id=?` for the _same_ chat
     (e.g. a burst of messages, or two devices logged into the same account) genuinely deadlocks on
     MySQL (Prisma error P2034). Fixed with `src/lib/withRetry.ts` — a jittered-backoff retry wrapper,
     now used by `sendMessage` and `markReceipts`. Both fixes are load-bearing for the real deployment,
     not just test-environment noise: any chat with simultaneous senders would have hit them.
- Not yet built (Phase 7): FCM push on new message — the mobile app currently relies on Firestore's
  push trigger; the new API needs the relocated `sendToTokens` call wired into `sendMessage`.

## Phase 6 — orders, leaderboard, notifications, quick replies, notification-requests (done)

- `server/src/orders/` — `POST /chats/:chatId/orders` (`{itemQuantity}`, admin side of that chat
  only), `GET /orders` (superadmin sees all, optionally `?storeId=`; store admin only their own via
  required `?storeId=`). `acceptOrder` creates the order + upserts the `store_leaderboard` row in one
  transaction, then calls `chats/service.ts`'s `sendMessage` for the "Order accepted ✅" system message
  (`orderId` set) — reusing it instead of duplicating the chat-update/publish logic means the order
  system message gets the exact same realtime fan-out a normal message does, for free.
- `server/src/stores/routes.ts` — added `GET /stores/:id/leaderboard` (public read, top 20 by
  quantity) next to the other public store reads.
- `server/src/notifications/` — `GET /notifications`, `POST /notifications/:id/read`,
  `POST /notifications/read-all`, `POST /notifications/broadcast` (superadmin only).
  `broadcastToAllUsers(title, body)` is the shared fan-out both direct broadcast and an _approved_
  notification-request call — same as the old `broadcastToAllUsers` helper serving both
  `broadcastNotification` and `decideNotificationRequest`. `push.ts` is a deliberate no-op stub so
  every call site is already wired for Phase 7 to fill in with a real FCM send.
- `server/src/quickReplies/` — store-admin-scoped CRUD (`GET`/`POST /stores/:storeId/quick-replies`,
  `PATCH`/`DELETE /quick-replies/:id`), same "resolve the owning storeId, then check admin" pattern
  already used for posts/stories.
- `server/src/notificationRequests/` — `POST /stores/:storeId/notification-requests` (store admin),
  `GET /notification-requests` (role-scoped like orders), `POST /notification-requests/:id/decide`
  (superadmin only; `409 ALREADY_DECIDED` if the request isn't still pending — verified live). Approve
  broadcasts using the request's own denormalized `storeName` as the push title, matching the old
  callable's contract exactly (store admins only ever type a message body).
- Verified live end-to-end against real MySQL: order acceptance → system message appears in the chat →
  leaderboard entry created/incremented → non-admin gets `403` → quick-reply CRUD with authz →
  notification-request create → superadmin list-by-status → approve → `409` on a second decide →
  the customer's `/notifications` list shows the broadcast → direct superadmin broadcast also works →
  admin is `403`'d from direct broadcast → mark-all-read.
- Caught and ruled out a real-looking bug: an emoji got mangled to `??` in one manual curl test.
  Traced it to the Bash tool's shell-argument encoding on this Windows environment, **not** a server or
  MySQL charset bug — confirmed by round-tripping emoji + Cyrillic text both directly through Prisma
  and through an actual HTTP POST with a file-based JSON body (bypassing shell quoting entirely); both
  came back byte-identical. Worth knowing MySQL/Prisma's UTF-8 handling here is solid, since this is a
  Turkmen/Russian-language app where this would otherwise be a serious, easy-to-miss data-corruption risk.

## Phase 7 — FCM relocated into the new API (done)

The Firebase Admin SDK service-account key didn't exist anywhere in this repo (by design — it's a
credential, never committed). Generated a fresh one for the existing `firebase-adminsdk-fbsvc@
semay-b57ee.iam.gserviceaccount.com` account (the same one `backend/functions` already used) via
`gcloud iam service-accounts keys create`, at the owner's explicit request. `gcloud` itself wasn't
installed either — added via `winget install Google.CloudSDK`, then `gcloud auth login` (interactive
browser OAuth, approved by the owner as `serdarhydyrow1996@gmail.com`) — same pattern as the earlier
MySQL/MinIO installs, just for a credential-issuing tool instead of a database. The key lives at
`server/serviceAccount.json`, confirmed `git check-ignore`'d before anything else touched it (matches
`.env.example`'s existing `GOOGLE_APPLICATION_CREDENTIALS="./serviceAccount.json"`).

- `server/src/lib/firebaseAdmin.ts` — initializes the Admin SDK's messaging client from
  `GOOGLE_APPLICATION_CREDENTIALS`; guarded (not required) so a dev box without a service account still
  boots, just with push silently disabled rather than crashing.
- `server/src/notifications/push.ts` — `sendPushToUsers` is now a real `sendEachForMulticast` call
  (previously the Phase 6 no-op stub every call site was already wired for). Dead tokens (uninstalled
  app, cleared data, or just malformed) are pruned from `user_fcm_tokens` automatically on send failure
  — replaces the ad hoc cleanup the old `arrayUnion`-based token list never really had.
- `server/src/users/routes.ts` — `POST`/`DELETE /users/me/fcm-tokens`. `UNIQUE(token)` + upsert-on-
  conflict reassigns ownership on reinstall/relogin, the fix the plan called out for the old
  `arrayUnion` ambiguity (two accounts both believing they own one stale token on the same phone).
- `chats/service.ts`'s `sendMessage` now sends a real push after the transaction commits (fire-and-
  forget — push is best-effort and must never fail the message send). Suppression matches the old
  trigger's contract exactly: muted chat → nothing; message _to_ the user side → skipped if their
  `activeChatId` already equals this chat (reuses the same flag already computed for the unread-
  counter decision, no extra query) — **superseded in Phase 9c**: that suppression left a chat
  permanently silent after a killed app, and now lives on the device only; message _to_ the admin
  side → pushed to every admin of that store
  (no single-recipient suppression, matching the unread-counter logic's same reasoning). `orders/
service.ts`'s superadmin notify and `notifications/service.ts`'s broadcast, both stubbed in Phase 6,
  now send for real through the same `sendPushToUsers`.
- **Verified against the real Firebase project, not just code review**: sent directly to a garbage
  token and got back a genuine `messaging/invalid-argument` FCM error (proves real auth + API
  connectivity — an auth/config failure would look completely different). Then ran the full pipeline
  live: registered a token via the API → triggered a real chat message → confirmed the token was
  actually gone from MySQL afterward (the async prune took a few seconds — a first check at 1s still
  showed the token, a second check at 6s showed it pruned; not a bug, just real network latency to
  Google's API that a hasty test almost mis-read as a failure).
- Real push delivery to an actual device isn't verified yet — that needs a real mobile install with a
  real registered token, which only exists once Phase 9 (mobile rewrite) repoints the app's token
  registration and delivery-receipt writes at this API instead of Firestore. Everything server-side
  that push depends on is done and proven against the real Google API.

## Phase 8 — web-admin rewrite (done)

**Superadmin auth decision**: web-admin's login used Firebase Auth **email/password** — a completely
separate mechanism from everyone else's phone-OTP flow, and the new `users` schema has no email/
password columns at all. Asked the owner rather than guessing (CLAUDE.md's "don't invent product
decisions" rule): **superadmin now uses the same phone-OTP flow as mobile** — one auth system, no new
schema fields. A superadmin is just a `users` row with `role='superadmin'`.
>
> **Superseded 2026-07-30** — see `docs/08_OPERATIONS.md` §9. The owner
> explicitly asked for phone+password login on the superadmin panel instead;
> `users.passwordHash` exists now, scoped to that one panel. Mobile and every
> other role still use OTP exactly as decided here.

- **Session model** — `access_token`/`refresh_token` httpOnly cookies (JWT + opaque, same tokens
  `server/`'s `/auth/otp/verify` and `/auth/refresh` issue). `src/proxy.ts` is the fast, optimistic
  gate (local JWT verify only) **and** the only place a near-expired token can be silently refreshed —
  Server Components can't set cookies mid-render, so silent renewal has to live in middleware
  (rewrites the incoming request's cookie via `request.cookies.set` + `NextResponse.next({request})`
  so the _same_ request's Server Components already see the fresh token, not just the next one).
  `src/lib/session.ts`'s `requireSuperAdmin()` is the secure re-check every page still runs — same
  "defense in depth" shape the old Firebase session-cookie code had, just backed by a fresh Prisma
  read of `role` instead of `verifySessionCookie(..., true)`.
- **Direct Prisma access** — `web-admin/scripts/sync-schema.mjs` copies `server/prisma/schema.prisma`
  into `web-admin/prisma/` before every `dev`/`build`/`generate` (gitignored — never hand-edited, so
  the schema can't fork into two sources of truth). Every page's data read goes straight through
  Prisma against the same MySQL database `server/` uses — the same trust perimeter the old `adminDb`
  (Firestore Admin SDK) access had.
- **Mutations split two ways**, matching the plan's "route publish-triggering mutations through the
  shared service function" instruction: store create/delete, store-admin grant/revoke, broadcast, and
  notification-request decisions all proxy over HTTP to the real `server/` API (`src/lib/apiClient.ts`
  - a `src/app/api/*` Route Handler per action) — these need `server/`'s transactional side effects
    (`claims_version` bumps, real FCM sends) that only exist there. Plain field writes with no side
    effects (leaderboard reorder, campaign start date, gift-image upload) go straight through Prisma (and
    a duplicated small MinIO client, `src/lib/minio.ts`) — no need to round-trip through the API for
    those.
- **`/api/users/lookup` got structurally simpler**: the old Firestore version had to reject a
  multi-account-same-phone match (`409`) — `users.phone UNIQUE` makes that case impossible now, so the
  lookup is just `findUnique`.
- Deleted the entire `maintenance` page + `DuplicateCleanup` component — the duplicate-Firestore-user
  bug it existed to clean up is the same one `users.phone UNIQUE` eliminated structurally.
- **Two real bugs found live-testing this phase, both now fixed**:
  1. `apiClient.ts` unconditionally sent `Content-Type: application/json` even on bodyless requests
     (e.g. `DELETE /stores/:id`) — Fastify rejects an empty body sent with that header
     (`FST_ERR_CTP_EMPTY_JSON_BODY`). Fixed by only setting the header when a body is actually present.
  2. `notifications/routes.ts` and `notificationRequests/service.ts` both destructured only `{ sent }`
     off `broadcastToAllUsers`'s result and dropped `failed` before it ever reached the response —
     silently regressing the old callable's `{sent, failed}` shape (added in this same phase, then
     immediately broken by these two call sites before ever shipping). Caught by web-admin's live
     broadcast test returning `{"sent":2}` with no `failed` key; fixed both call sites to forward the
     full result.
- **Verified live, end-to-end, against the real running stack** (not just typecheck): unauthenticated
  redirect → phone+OTP login → every protected page renders with real seeded data → create store →
  promote/revoke admin (with a live re-render check) → leaderboard reorder + campaign date → gift-image
  upload through MinIO and fetched back → a store-admin's notification request created via the real API,
  approved through web-admin, confirmed gone from the pending list → broadcast → **non-superadmin login
  correctly rejected with 403 and no cookie set** → logout → protected route redirects again.
- Rewrote `web-admin/scripts/seed.ts` for MySQL/Prisma — the old script's entire "dev OTP-bypass
  email/password convention" section is gone; `OTP_DEV_MODE=true` on `server/` (code echoed in the send
  response) replaces the need for any bypass account at all.

## Phase 9 — mobile rewrite (done; 9b offline outbox deferred)

The whole Flutter app now talks to `server/` over REST + one multiplexed WebSocket instead of the
Firebase SDKs. `firebase_auth`/`cloud_firestore`/`firebase_storage`/`cloud_functions` are removed from
`pubspec.yaml`; **only `firebase_core` + `firebase_messaging` remain** (FCM push, unchanged on the
client — just the server-side _send_ moved in Phase 7). The full debug APK builds and `flutter
analyze` is clean.

- **New client core** (`mobile/lib/core/`): `session.dart` (access JWT decoded locally for
  role/storeIds/claimsVersion — replaces the whole `_syncedIdTokenResultProvider` claims-drift hack;
  refresh tokens in `flutter_secure_storage`), `api_client.dart` (Dio + interceptor that attaches the
  bearer and does one-shot 401/`CLAIMS_STALE` → `/auth/refresh` → retry, clearing the session on
  refresh failure so the router's existing redirect handles logout), `realtime_client.dart` (single WS
  connection, ref-counted per-channel multiplexer so `StreamProvider.family(..., isAutoDispose: true)`
  transparently becomes the real WS unsubscribe — the design the plan called highest-risk, now built
  and verified), `json_ext.dart` (`JsonDoc` wrapper preserving the exact `.id`/`.data()` surface the
  ~15 consuming screens read, so only providers changed, not screens; `parseTimestamp` for ISO-string
  dates, `normalizePost` folding the API's `media[]` back into the `mediaUrls[]` shape screens expect).
- **Wire-format shifts handled once, centrally**: Firestore `Timestamp` → ISO-8601 strings
  (`parseTimestamp`), Prisma `Decimal` (`"19.99"`) → num, BigInt message ids → strings, `media[]`
  objects → `mediaUrls[]`, notification `read` bool → nullable `readAt`. The `JsonDoc` wrapper meant the
  bulk of screen code (`doc.id`, `doc.data()['field']`) never changed.
- **Realtime channels wired**: `post:{id}` (like/save counts on cards), `store:{id}` (live store
  profile/summary), `chat:{id}` + `chat:{id}:messages` (thread), and the two list-diff channels
  `user:{uid}:chats` / `store:{storeId}:chats` (chat lists — an admin merges one channel per managed
  store client-side; the server snapshot caps at 100/store, replacing the old client-side pagination).
  Everything else (feed, reels, stories, leaderboard, orders, notifications, notification-requests,
  quick-replies, liked/saved grids) is REST + pull-to-refresh, matching the plan's scope.
- **Small backend endpoints added just-in-time** as each mobile surface needed them, each verified
  live: `likedByMe`/`savedByMe` on all post reads + `GET /users/me/liked|saved` (a batched two-query
  annotate, replacing the dropped Firestore mirror collections), `PATCH /posts/:id` (caption edit),
  `GET /stories/rings` + `POST /stores/:id/story-seen` + `GET /stories/:id/views` (story bar seen-state
  computed server-side instead of the old 3-listener client stitch), `GET /users/:id` (admin sees the
  customer's name/phone in a chat; phone gated to admin/superadmin), `PATCH /stores/:id` (store-admin
  self-service edit), `POST /auth/change-phone` (OTP-verify-new-number-then-repoint, 409 on collision),
  and `attemptsRemaining` on `OTP_INVALID`.
- **Verified live against the running stack** (server curl + real device APK build; I can't visually
  inspect screens, so full UI click-through is the owner's job): OTP login end-to-end with the physical
  device reaching `server/` over `adb reverse tcp:8080`; session survives app kill+relaunch; the
  presigned-upload → MinIO PUT → create-post → read-back-with-flags → caption-patch → delete pipeline;
  story create/rings/seen-flip/view-count; the full two-account chat flow (create → send → admin unread
  → reply → read-receipt flips `readAt` → typing → accept-order with auto-filled phone) plus the
  `/users/:id` phone-gating (admin sees it, a plain user never sees another user's phone); `PATCH
/stores/:id` and `GET /orders`.
- **Deferred to 9b (unchanged from the original plan)**: the offline SQLite outbox and the read-side
  local cache. Until then, a fresh app launch shows a brief loader instead of Firestore's
  instant-stale-then-fresh paint, and a message/like sent with no signal isn't queued for replay — both
  known, documented gaps, not regressions introduced here.
- A leftover cross-cutting note: `main.dart` lost all the Firebase-emulator wiring (4 `useXEmulator`
  calls) and the manual `NotificationService` construction; the foreground-message listener is now a
  top-level function so it still registers once before `runApp` without needing a `ProviderScope`.

## Phase 9b — offline outbox + read-side cache (done)

The two things Firestore gave for free that the plan flagged as the biggest client lift.

- **Server foundation**: `messages.clientKey VARCHAR(64)`, unique **per chat**
  (`UNIQUE(chatId, clientKey)` — migration `20260725035809_add_message_client_key`, narrowed from a
  global unique by `20260829160413_scope_message_clientkey_to_chat`). `sendMessage` dedupes on it: a
  fast-path lookup scoped to `(chatId, senderId)` returns the already-created message on a retry, and
  a concurrent same-key burst that slips past the fast path is caught on the `P2002` unique-violation
  and re-fetches the winner — so a replayed outbox can **never** double-send.

  The scoping is a security fix, not a tidy-up. While the constraint was global, the lookup was an
  unscoped `findUnique`, so replaying any key returned **whatever row owned it** — a stranger's
  private message, complete with text, sender and timestamps, from a chat the caller gets `403` on.
  It was silent data loss too: the caller's own message was never written, yet they received `201`,
  and the outbox drops an item on any 2xx. Orders mint structurally derivable keys (`order:{id}`), so
  the keyspace was not purely random either. Per-chat uniqueness is what the idempotency needed all
  along — a genuine retry always targets the same chat. Verified live (send twice + 5-way concurrent
  race → one row) and covered
  by `tests/message.idempotency.test.ts` (retry + 10-way concurrent burst → exactly one row); 32/32
  server tests pass. Like/save need no key — they're already idempotent on their composite PKs.
- **Client outbox** (`mobile/lib/core/outbox.dart`): a durable `sqflite` queue (`connectivity_plus` +
  `uuid`), scoped per the plan to **chat messages + like/save toggles**. Enqueue is optimistic and
  fire-and-forget; a drain worker runs on enqueue and on every connectivity change, oldest-first, with
  a broadcast `changes` stream driving the UI. Failure handling: a permanent 4xx (validation/authz/
  not-found, except 401 which the Dio interceptor already tried to refresh) **drops** the poison item
  so it can't wedge the queue; a 5xx / network error / post-refresh 401 bumps the attempt count and
  stops the drain to retry on the next reconnect. `ChatService.sendMessage` and `PostsService.toggle
Like/Save` now route through it (messages carry a client-generated `clientKey`).
- **Optimistic message rendering**: `mergedChatMessagesProvider` overlays still-unsent outbox messages
  onto the live `chat:{id}:messages` channel list as synthetic bubbles, de-duped by `clientKey` — so a
  message sent offline appears instantly and vanishes the moment the server echoes the real one back.
  The thread screen watches the merged provider; the pure server stream stays underneath unchanged.
- **Read-side cache** (`mobile/lib/core/read_cache.dart`): a small `sqflite` key→JSON store persisting
  the first page of `feed` / `store posts` / `store reels`. `build()` paints the last-seen page
  instantly before the network fetch supersedes it — restoring Firestore's `Source.cache` instant-paint
  (best-effort: a miss or error just falls through to network).
- `main.dart` now boots one app-lifetime `ProviderContainer` (via `UncontrolledProviderScope`) so the
  outbox's SQLite queue + reconnect drain start at launch and the same instance is shared with the
  widget tree. `flutter analyze` clean; full debug APK builds with the new native plugins linked.
- **Still owner-verified only**: the true airplane-mode → send-offline → restore-signal → replay-once
  loop needs a physical device with toggled connectivity, which is part of Phase 10's on-device matrix
  (I verified the server-side no-dupe guarantee and that everything compiles/links).

## Phase 9c — chat reliability pass (done)

The complaint: messages did not arrive or send promptly, no notification for new messages, no
unread badges. Every one of those traced to the realtime/push plumbing, not the chat logic —
`docs/08_OPERATIONS.md` §3a/§3b holds the full failure→fix table and the reasoning; this is the
change list.

- **`mobile/lib/core/realtime_client.dart` rewritten.** Heartbeat (dart:io `pingInterval` 20 s),
  fresh access token before every connect (the old client reconnected with the stored token, which
  after 15 min the server refused with 4401 — and it retried with the same dead token every 2 s
  forever), exponential backoff with jitter, reconnect on connect failure (previously never
  scheduled), a liveness probe on app resume and on network change (app-level `{type:"ping"}` →
  `{type:"pong"}`, new in `gateway.ts`), a new socket on login/logout, and the connection state
  (`realtimeConnectionProvider`) surfaced as "Connecting…" under the chat title (thread + list),
  the way WhatsApp/Telegram do.
- **`server/src/realtime/gateway.ts`**: answers `{type:"ping"}`; server-side ws ping every 30 s and
  `terminate()` on a missed pong, so dead sockets stop holding listeners.
- **`api_client.dart`**: token refresh is single-flight (`RefreshOutcome`), the interceptor logs out
  only on a *rejected* refresh (an unreachable server used to log people out), and the shared Dio has
  receive/send timeouts (a hung request could wedge the outbox forever). `AccessTokenSource` is the
  "valid token, refreshing if needed" the socket asks for.
- **Send path.** The outbox emits `SentMessage` from the POST response and `chatMessagesProvider`
  merges it, so a sent message appears the instant the server accepts it even with the socket down
  (it used to vanish: bubble removed, echo never came). Outbox retries on a timer with backoff, shows
  a clock while pending and, after `outboxFailedAfterAttempts`, a red "not sent — tap to retry".
- **Receipts.** New `receipts` realtime event (`bus.ts`) replaces the 200-message re-snapshot
  `markReceipts` used to publish. Delivered receipts now also fire from the chat-list channels
  (`_DeliveryMarker` in `chat_providers.dart`) when a chat's unread rises on the device — the second
  grey check no longer depends on FCM being configured/allowed/unmuted.
- **Push.** Server-side `activeChatId` suppression removed from both the unread increment and the
  push (`sendMessage`); the app's in-app banner keeps the local check. `push.ts` gained
  `PushOptions` (channel, per-chat tag, per-recipient badge, `contentAvailable`) and
  `sendBadgeUpdate` (iOS badge-only correction after a read). Admin-side pushes are titled by the
  customer's name. A notification tap opens the thread (`listenNotificationTaps`: cold start via
  `getInitialMessage`, background via `onMessageOpenedApp` — neither was handled). Android:
  `chat_messages` channel at IMPORTANCE_HIGH created in `MainActivity.kt` + manifest default. iOS:
  `Runner.entitlements` (`aps-environment`) registered in the Xcode project and
  `UIBackgroundModes: remote-notification` — without the entitlement no push could ever arrive on
  iOS. Still needed outside the repo: APNs key in the Firebase project, Push capability on the App ID.
- **Tests**: `tests/realtime.gateway.test.ts` boots a real listener and drives a real `ws` client —
  4401 on a bad token, ping/pong, snapshot → upsert → `receipts` (and that a redundant receipt
  publishes nothing), stranger refused, and unread counting with `activeChatId` set. Full suite green.
- **Not yet verified on a device** (the reason this pass stops here): the resume/network-change
  reconnect, Android heads-up + tap-to-open, and the iOS push chain end to end.

## Post-migration feature changes (after Phase 9b)

Product tweaks requested once the migrated stack was running — logged here so the
behavior stays traceable to a decision, same as the phases above.

- **View/send/share are now client-buffered, not once-ever.** The old model wrote a per-user
  `PostView`/`PostSent`/`PostShare` row (composite PK) so a user could only ever count each once. That's
  replaced by a local buffer (`mobile/lib/core/interaction_buffer.dart`, SQLite): the _same_ user
  re-counts a post's view/send/share after a **30-minute window**, and nothing hits the network per tap
  — taps accumulate and flush as one batch every ~30 min, on app background, and once at startup (to
  drain the last session). The window and the flush are the same cycle: a successful flush is what
  re-opens counting ("re-count after sending to server"). A failed flush keeps the rows and never
  resets the window, so no count is dropped. Server side: the three once-ever endpoints
  (`POST /posts/:id/view|sent|share`) are gone, replaced by one **`POST /posts/interactions`** that takes
  a batch of `{postId, views, sent, shares}` increments (`applyInteractionBatch`), bumps the
  denormalized counters, and republishes `post:{id}` counts. Dedup moved entirely client-side; the
  `PostView/PostSent/PostShare` tables remain in the schema (cascade targets) but no longer take writes.
  **Likes/saves are unchanged** — still per-user toggles through the offline outbox (they drive
  liked-by-me + the leaderboard, so they can't be lumped into anonymous increment batching). Covered by
  `tests/interaction.batch.test.ts` (accumulation across flushes + unknown-postId skip); 34/34 server
  tests pass.
- **Search is a shuffled discovery surface.** `searchablePostsProvider` shuffles the merged feed+reels
  once per session (stable until pull-to-refresh). Tapping a result no longer opens the single-post
  detail screen — it opens a **shuffled, continuously-scrolling pager of that media type**, seeded to the
  tapped item: `SearchPostsPagerScreen` for images/carousels, `SearchReelsPagerScreen` for reels
  ("posts and reels, separately"), both reusing the grid's shuffled order.
- **Media storage is a plain local folder, not MinIO.** The Phase 3/8 notes below describe a MinIO
  bucket + presigned URLs; that object store is gone. `server/src/media/storage.ts` writes uploads as
  plain files under `MEDIA_DIR` (`server/media/`, gitignored), served back by `@fastify/static` at
  `/media/*` with HTTP range support for video seeking. The presigned-upload *shape* is unchanged from
  the client's point of view — `POST /media/upload-url` still returns a 5-minute upload URL, but it's
  now an HMAC-signed `PUT /api/v1/media/blob/*` on the API itself rather than a MinIO URL, with a path
  traversal guard (`pathForKey`) and a 120MB cap. One fewer service for the owner to run and back up;
  in production the folder can be fronted by a Caddy/Nginx `file_server` for performance.
  `web-admin`'s duplicated MinIO client was deleted (it had no remaining importers) along with the
  `minio` dependency in both packages.
- **Logs are written to disk.** `server/src/lib/logging.ts` adds a `pino-roll` transport alongside the
  console one: newline-delimited JSON to `LOG_DIR/app.<date>.log` (`server/logs/`, gitignored), rotated
  daily and pruned to `LOG_RETENTION_DAYS` (default 14) files so they can't grow unbounded on the
  server. `LOG_LEVEL` is configurable; pretty console output stays for non-production only. Previously
  logs went to stdout exclusively, so anything not captured by the process supervisor was lost.
- **Super-admin orders report**: the dashboard `OrdersTable` gained a total-orders + total-items
  summary, an inclusive **date-range (from/to) calendar filter**, and a click-to-toggle **sort-by-date**
  column header. All client-side over the existing 90-day fetch — no schema or API change.

## Things Firebase gave "for free" that need real new work

- Offline write queue/replay → client SQLite **outbox** (Phase 9b; scoped to chat messages +
  like/save for v1, idempotency-keyed).
- Disk-cache instant-paint → hand-rolled read-side local cache.
- Per-listener query-result diffing → hand-written list-channel membership (chat lists only).
- Zero server ops → the team now owns MySQL backups, patching, TLS, on-call. Backup-restore drill
  required before cutover.
- FCM itself is **not** a gap — purely relocated into the Node process.

## Local dev

```bash
cd server
cp .env.example .env        # fill DATABASE_URL, JWT_SECRET, etc.
npm install
npm run prisma:generate
npm run prisma:migrate      # creates tables against DATABASE_URL
npm run dev                 # tsx watch on src/index.ts
```
