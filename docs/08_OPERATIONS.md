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
| 1 | **`REDIS_URL` set** whenever more than one process serves traffic | A Node process only shares realtime events with sockets it owns. Without Redis, two users on different workers never see each other's messages — the app looks fine and silently loses chat delivery. `start:cluster` refuses to boot without it — or with one that does not answer (§3d). | `server/src/realtime/bus.ts` |
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
| Reconnect after 15 min reused the expired access token → server `4401` → retry every 2 s with the same dead token, forever | A fresh token is obtained *before* every connect (`AccessTokenSource.validToken`, refreshing when less than `min(60 s, TTL/3)` remains — read from the token's own `iat`/`exp`); a `4401` close forces a refresh on the next attempt | `api_client.dart`, `realtime_client.dart` |
| A connect that threw never scheduled a retry | Exponential backoff with ±50 % jitter (1 s → 30 s); a connection that lived ≥ 5 s resets it so the first retry after a real drop is immediate | `realtime_client.dart` |
| Nothing reconnected on app resume, network change, or login/logout | On resume/online: an application-level `{type:"ping"}` with a 5 s deadline, reconnect on silence. On session change: new socket (the old one authenticated as the old user) | `main.dart`, `realtime_client.dart`, `gateway.ts` |
| A same-user token refresh looked like a login. The session-change guard compared against the uid of the *attached* socket, unknown until the handshake — and `_connect` refreshes the token *before* it opens the socket — so every connect that refreshed bumped the session epoch, discarded the socket it had just opened and reconnected. One wasted handshake + refresh per reconnect at the production TTL; with a TTL below the old flat 60 s refresh margin (test/ops configs) a loop of ~600 refreshes in 6 s, ended only by the `/auth/refresh` rate limiter | The guard keys on the *session's* uid (seeded from the stored session at start-up, so a stored session's first refresh is not a "login" either); the refresh margin follows the TTL (`min(60 s, TTL/3)`); and a circuit breaker refuses a sixth refresh inside one minute for 30 s — reported as *unreachable*, so nothing logs out | `realtime_client.dart`, `api_client.dart` |
| The server accepts the socket and answers pings but never delivers — its Redis bus down or unreachable (the server side of this is documented with the bus in this file). The phone showed `connected`: no caption, no retry. Sent messages appeared (the POST response), incoming ones only after reopening the thread (the REST seed) — the "messages stop after a couple, I have to reopen the app" report | The client measures SILENCE, not elapsed time since a subscribe: a socket with at least one subscribe outstanding that delivers **nothing for 25 s** (`RealtimeClient.snapshotDeadline`, evaluated on a 5 s sweep — any delivered frame resets it for every channel, so one slow channel on a working socket never trips it) — or a **second** `SUBSCRIBE_FAILED` for one channel on one socket — puts the client in `stalled` ("Connecting…" shows), closes the socket and reconnects through the normal backoff (never a tight loop: 25 s deadline + up to ~45 s jittered backoff, so ~70 s worst case per attempt). A per-channel stopwatch armed at subscribe time was the first attempt and had to be replaced: an app launch subscribes to ~20 channels whose snapshots serialise over one connection, so it fired on healthy-but-slow servers and never converged. The separate **10 s** bound is the SERVER's (`SUBSCRIBE_DEADLINE_MS`, `gateway.ts`), after which it answers `SUBSCRIBE_FAILED` rather than nothing. Every reconnect announces the channels it re-subscribed (`RealtimeClient.resyncs`), on which the open thread and both chat lists re-fetch over REST (`GET /chats/:id/messages`, `GET /chats`), so a snapshot that never comes cannot freeze them; the chat list, previously cache + socket only, gained that REST copy (an empty list on a fresh install with a dead bus was the other symptom). That re-seed is rate-limited per channel (`RealtimeClient.resyncInterval`, 10 s — shorter than the 25 s stall cycle, so it drops only the redundant announcement from a reconnect that DID get its snapshot) so a flapping server cannot turn every phone's reconnect into DB-backed REST calls aimed at the component already failing. The socket supersedes REST: an answer that a frame overtook while in flight is dropped, not merged | `realtime_client.dart`, `chat_providers.dart` |
| **`REDIS_URL` set but Redis dead or unreachable** — not running after a reboot, wrong host, a dev `.env` copied to a box without the service. ioredis queued every publish in process memory, `SUBSCRIBE` never settled so the gateway never sent a snapshot, every error event was swallowed, the boot line still said "Redis pub-sub" and `/health/ready` only asked the DB. Sockets open, pings answered, nothing delivered — on every phone at once, and nothing on the server said so | The bus routes through Redis only while both connections are confirmed live and otherwise delivers in-process (complete for one process); a `SUBSCRIBE` is bounded at 3 s and never waits on a Redis ioredis is backing off from, so the snapshot goes out regardless; the gateway bounds the whole subscribe at 10 s and answers `SUBSCRIBE_FAILED` instead of nothing; boot logs an error naming the host; `/health/ready` reports `bus.ready:false` + `degraded:true`; `start:cluster` refuses to fork. Details in §3d | `bus.ts`, `gateway.ts`, `index.ts`, `cluster.ts`, `app.ts` |

Related fixes in the same pass:

- **Concurrent token refresh** is single-flight. The REST interceptor and the
  socket can both notice an expired token in the same instant; the server
  rotates the refresh token on every call, so the second refresh presented an
  already-revoked token and the session was killed for nothing. The interceptor
  also no longer logs out when the refresh endpoint was merely *unreachable* —
  only when it *rejected* the token. The server has since grown a reuse grace
  (§3c), so a second refresh with the same token is honoured even when one
  does slip through.
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
- **A refresh is "rejected" only on an explicit `401 SESSION_INVALID`.** A 429
  from the rate limiter (carrier NAT puts many phones behind one IP), a 5xx, a
  timeout — originally even a 400/403 — used to count as rejection and log the
  user out; now everything but the server's own verdict on the token is
  "unreachable": retried once after 2 s, otherwise left to the next request,
  session kept (§3c). A logout that completes while a refresh is in flight
  also wins over that refresh.

### 3b. Push: what the server sends and why

- **No server-side suppression.** `users.activeChatId` used to skip both the
  push and the unread increment when it matched the chat. The flag is written by
  the app on enter/leave; a killed app, a crash, or a PATCH lost to bad signal
  left it stuck, and that chat then never badged or notified its user again.
  Whether someone is looking at a thread is only knowable on their device, so
  the app suppresses its own foreground notification for that one chat and
  the server counts and pushes regardless. The thread screen answers each
  incoming message with a read receipt within one round-trip, so the counter
  is back at 0 before anyone sees it. The column is kept as a diagnostic hint
  only.
- **Chat payload** (`notifications/push.ts`, set by `chats/service.ts`):
  `android.priority=high` (wakes a dozing device), `channelId=chat_messages`
  (a channel the app creates at IMPORTANCE_HIGH with no sound of its own —
  heads-up banner + the phone's default notification sound; FCM's default
  "Miscellaneous" channel is silent — see "Notification sound" below),
  `sound=default` on both platforms (Android `android.notification.sound`,
  only consulted below API 26, where there are no channels; from 26 on the
  channel's sound wins — and iOS `aps.sound`), `tag=<chatId>`
  (one notification per conversation, newest replaces oldest; iOS `thread-id`
  groups them), `contentAvailable` (iOS wakes the app to post the delivered
  receipt), and `data:{type:"chat_message",chatId,messageId,senderRole}` —
  `chatId` is what a notification tap routes to.
- **Broadcast payload** (`notifications/service.ts`): same priority and sound,
  `channelId=announcements` (a second IMPORTANCE_HIGH channel the app creates
  next to the chat one, so a user can silence announcements in system settings
  without silencing chats; an app older than the channel falls back to the
  manifest default — today `chat_messages` — so
  the server side could ship first),
  `tag=broadcast` (a newer unread announcement replaces the older one in the
  shade — the inbox keeps every one), `data:{type:"broadcast"}` (routes a tap
  to the inbox and tells an open app to refetch it), and **no**
  `contentAvailable`. The inbox row (`user_notifications`) is written first and
  is the durable record; the push runs in the background after the response,
  and its tally is logged as `broadcast push done {users, sent, failed}` (or
  `broadcast push failed`). The response carries `pushEnabled` and, when false,
  `pushDisabledReason`, and the panel shows both — `sent` counts inbox rows,
  never pushes. Order notices (`orders/service.ts`) go on `channelId=orders`
  (a third IMPORTANCE_HIGH channel, default sound — so a superadmin can
  silence order notices without silencing chats, and an order notice does not
  land in the chat category by falling through to the manifest default) with
  no tag; posted by the app in the foreground they get no tag and their own
  id, so they stack instead of overwriting a pending announcement (or being
  overwritten by the next one). **That holds only once the server that
  names `orders` is live, so redeploy the server before (or with) the app
  release.** This is the one ship order that is not symmetric: only the server
  names the `orders` channel, so a NEW app taking an order push from an OLD
  server (which sends no `channelId`) falls through to the manifest default —
  the chat channel. All three channels sound the same (the device default), so
  the cost is a miscategorised notice, not a wrong noise. Backgrounded/killed
  superadmins only; a foreground order notice is posted on `orders` by the app
  regardless of the server. See docs/09 §14.
- **Every string the server writes for a person is Turkmen or Russian, never
  English** — `src/lib/copy.ts`, the server-side counterpart of the app's
  `mobile/lib/core/l10n.dart` (the product ships tk/ru only, by decision; the
  Android channel names live in `res/values` + `res/values-ru` for the same
  reason). A push takes the **recipient's** `users.language`:
  `sendLocalizedPushToUsers` (`notifications/push.ts`) groups the recipients by
  language and sends one multicast per group — at most two — because a payload
  carries a single title/body for the whole batch; `badgeByUser` is a per-user
  map, so it survives the split, and a recipient whose row is gone falls back to
  `tk`, the schema default. The copy this covers is the chat push's fallback
  title (seen only when neither the sender's name nor the store's is set), the
  order notice's title and body, and the confirmation message `orders/service.ts`
  posts into the chat. That last one is **one persisted row both sides read**, so
  it cannot follow the reader: it is written in the CUSTOMER's language (the
  message informs the customer; the admin is reading back their own tap) and it
  doubles as that push's body. A chat push's body is the message itself and is
  never translated (`[media]` for a media-only message is a language-neutral
  placeholder, and a broadcast's title/body is whatever the superadmin typed).
  Pinned by `tests/push.localized-copy.test.ts`.
- **Broadcast recipients are `deletedAt: null`.** `DELETE /users/me` is a
  scrub, not a row delete (the row survives so orders keep a valid FK —
  `users/service.ts` `deleteAccount`), so an unfiltered fan-out kept writing a
  `user_notifications` row per broadcast, forever, for accounts that had been
  told their data was removed, and counted them in the `sent` the panel shows.
  Nothing rang — their FCM tokens are deleted — but it was retention against a
  deleted account. Pinned by "skips accounts that have been deleted" in
  `tests/notifications.broadcast.test.ts`.

  Filtering the recipient list is necessary but not sufficient, because the
  list is read seconds before the rows are written. `insertChunk` therefore
  writes each chunk as a single **`INSERT … SELECT … FROM users WHERE
  deletedAt IS NULL AND id IN (…)`** instead of reading ids and then
  `createMany`-ing them. That one statement closes both races at once:
  - a **hard**-deleted id selects no row, so there is no `P2003` to turn into
    a 409 — one deletion used to cost all 5000 users in that chunk their
    announcement;
  - a **soft** delete is beaten by the SELECT being a *locking* read inside the
    insert: `deleteAccount` runs in a transaction whose `deleteMany` gap-locks
    the `user_notifications` index range, so a plain insert blocks and then
    lands *after* the commit, leaving one row on a just-scrubbed account. The
    locking read blocks on the same lock and then re-reads, sees `deletedAt`
    set, and inserts nothing. (This was reproducible: it made
    `tests/account.deletion.test.ts` red in most full suite runs.)

  `sent` is the number of rows actually written, so the panel's count is
  recipients reached, never ids attempted; a shortfall is logged at **info** as
  `broadcast: recipient(s) deleted mid fan-out, skipped {listed, written}`.
  Info, not warn: the recipient list is one statement — several seconds at 100K
  users — ahead of the inserts, so at any real scale a broadcast overlapping a
  single `DELETE /users/me` lands there. Nothing is lost and nothing is
  actionable; the two numbers are recorded only so `sent` can be reconciled
  against the list it came from.
  Covered by `tests/notifications.broadcast-race.test.ts`.
- **While the app is open** FCM shows nothing by itself: on Android the SDK
  hands a foreground push to Dart and the heads-up a backgrounded app gets for
  free never appears, and on iOS the OS asks the app what to present. The app
  therefore posts the notification itself on Android
  (`flutter_local_notifications`, same channel, tag and id-0 identity FCM's own
  SDK uses, so it replaces rather than stacks; skipped only for the chat on
  screen; status-bar glyph `res/drawable/ic_notification`, also FCM's
  `default_notification_icon` in the manifest — the adaptive launcher icon is
  rejected as a small icon by Android 8.0, which kills the posting process)
  and on iOS asks the OS to present alert + sound + badge
  (`setForegroundNotificationPresentationOptions` in `main.dart` — global
  options; the one per-message exception, the thread on screen, is made in
  `AppDelegate.swift`, see "Notification sound" below). The previous in-app overlay
  banner is gone: it called
  `SystemSound.play(SystemSoundType.alert)`, which Flutter documents as ignored
  on Android and iOS, so it was silent by construction. A foreground broadcast
  also invalidates the REST-only inbox provider, which is what moves the
  feed's bell badge without a restart; the inbox screen marks read every list
  the server returns (not once per open), so the row its own refetch brings
  in — a broadcast that arrived while the app was away — is marked too.
- **Notification sound, and the one silent case.** Every push — chat,
  announcement, order notice — rings with the **phone's own default
  notification sound**. A bundled chat sound shipped in one round of local test
  builds (`res/raw/semay_message.mp3`, `Runner/semay_message.wav`) and the
  owner had it removed: *"normal notification with the phone's default sound"*.
  Both assets, the channel's `setSound` call, the Dart
  `RawResourceAndroidNotificationSound`, `res/raw/keep.xml` and the server's
  `androidSound`/`iosSound` options are gone; `notifications/push.ts` now sends
  a flat `sound: "default"` on both platforms. **Do not reintroduce a custom
  sound without re-reading the Android trap below** — it is why this section is
  long. What did *not* change is the suppression rule, the same on both
  platforms and stated once in code (`shouldPresentPush` in
  `notification_service.dart`): **a chat push is silent ONLY when its `chatId`
  equals the thread on screen with the app resumed; everything else — the chat
  list, the inbox, any other tab, a message for chat B while in chat A, a
  backgrounded or killed app — shows normally, with the default sound;
  broadcasts are never suppressed.** `ChatThreadScreen` sets the active chat on
  enter/resume and clears it on pause/dispose, which is what "on screen with
  the app resumed" means.
  - *Android.* All three channels are created with **no `setSound` call at
    all**, which is what gives them the system default sound — a channel
    created without one is not silent. Chat is on the original id
    `chat_messages`: every device running the last released build already has
    that channel, with the default sound, so there is nothing to migrate and no
    immutable-sound trap. `chat_messages_v2` — minted only because a channel's
    sound is fixed at creation, and only ever created by the intermediate test
    builds that carried the bundled sound — is **deleted** on every start
    (`deleteNotificationChannel(RETIRED_CHAT_CHANNEL_ID)`), so it does not sit
    in those handsets' notification settings as a stale, unused category. On
    one of those handsets `chat_messages` had itself been deleted by the
    intermediate build; re-creating a deleted channel restores its original
    settings, which were the default sound — the right outcome either way. All
    three channels are created in **`SemayApplication.kt`** — an `Application`
    subclass registered as `android:name=".SemayApplication"` in the manifest,
    in place of Flutter's `${applicationName}` placeholder (that placeholder is
    literally `android.app.Application`, the class this extends; it is also the
    hook the Flutter Gradle plugin uses to inject `FlutterMultiDexApplication`,
    which minSdk 24 does not need). **Not `MainActivity`**: FCM draws a
    backgrounded app's notification from inside `FirebaseMessagingService`,
    which starts the process — so `Application.onCreate` runs — but never
    starts `MainActivity`. Straight after a Play Store update the app has
    usually not been opened yet, so a channel created from the Activity would
    not exist when the first notification of the new version is drawn, and the
    SDK would post it on its own auto-created `fcm_fallback_notification_channel`
    ("Miscellaneous", IMPORTANCE_DEFAULT): no heads-up, no user-silenceable
    category of its own, and a stray one left in the app's notification
    settings for good. That is exactly the "an upgrade must not go silent"
    requirement, so keep channel creation in the Application.
    `SemayApplication.kt` also creates the `announcements` and `orders`
    channels. The manifest default
    (`com.google.firebase.messaging.default_notification_channel_id`) is
    `chat_messages`, the same id the server sends, so either side can ship
    first (the one exception is the `orders` channel — see §3b's broadcast
    bullet). A backgrounded app gets the channel's sound from FCM; the app's
    own foreground notification passes **no** sound, so the plugin never
    validates a raw resource and `invalid_sound` cannot happen. Its `show()` is
    still wrapped in a `try`, because the plugin throws rather than degrading
    (a bad small icon, `POST_NOTIFICATIONS` revoked mid-session) and that
    Future is deliberately not awaited by the `onMessage` listener — an
    unguarded throw became an unhandled async error
    (`test/services/foreground_notification_test.dart`).
    - **If a custom sound ever comes back, this is the trap it fell into.**
      Kept because the next person to try will hit it again. Flutter turns AGP
      resource shrinking on for *every* release build (`flutter_tools`'
      `FlutterPlugin.kt`:
      `releaseBuildType.isShrinkResources = isBuiltAsApp(project)`), and
      `res/raw/semay_message.mp3` was referenced by NAME from three places the
      shrinker cannot see: the Dart `RawResourceAndroidNotificationSound`, the
      FCM payload's `android.notification.sound` (resolved with
      `getIdentifier`), and a string-built
      `android.resource://…/raw/semay_message` channel URI. It therefore
      stripped the file from the release APK — release-only, and invisible to
      `flutter test`, `flutter analyze` and the server payload tests: the
      channel pointed at a resource that did not exist (backgrounded chat push
      = **silent**, worse than the default it replaced) and the foreground path
      threw `invalid_sound` and posted nothing at all. The two guards were
      `R.raw.semay_message` read from Kotlin (as the argument to
      `getResourceEntryName`, so the int constant stays in dex where the
      shrinker follows it) plus `res/raw/keep.xml` with
      `tools:keep="@raw/semay_message"`. The two requirements pull in opposite
      directions and both must hold: the shrinker needs the **id** referenced
      from code, the channel needs the **name** in the persisted URI, because
      aapt2 renumbers `res/raw` entries by position and Android persists the
      channel URI verbatim — an unresolvable channel sound is silent, and the
      channel can only be replaced (a `chat_messages_v3`), never repaired. All
      of that is gone with the sound; a future custom sound needs the whole
      construction back, plus a release-build check, not just a `setSound`.
  - *iOS.* The OS presents a foreground push itself and asks the
    `UNUserNotificationCenter` delegate what to show; Dart is never consulted,
    so the rule is mirrored natively. `AppDelegate.swift` makes itself that
    delegate **before** `super.application(_:didFinishLaunchingWithOptions:)`
    — required: `firebase_messaging` otherwise installs itself as the delegate
    and answers every `willPresent` with the global options, and
    `flutter_local_notifications` never takes the delegate at all (it stays
    Android-only here) — keeps the active chat that `setLocallyActiveChatId`
    mirrors over the `com.semay.semay/notifications` method channel
    (`setActiveChat`, fire-and-forget), and overrides `willPresent`: the
    thread on screen completes with `.badge` only, still through `super` so
    the FCM plugin fires `Messaging#onMessage` (the delivered receipt);
    anything else is forwarded unchanged, so the push's own `aps.sound` plays.
    This Swift is verified by the Codemagic build and on a device, not on the
    Windows dev box.
  - *Opening a thread clears its notification, on BOTH platforms.* A notice for
    a conversation the user is reading is stale the moment they open it, and
    leaving it makes them swipe away a banner for a message they have already
    read — which is neither what WhatsApp nor Instagram does.
    `dismissChatNotification(chatId)` is called from `ChatThreadScreen`; the
    identity differs per platform, so the routes do too. Android:
    `flutter_local_notifications.cancel(id: 0, tag: chatId)` — the same
    identity FCM's Android SDK uses, and what also drops the launcher count,
    which Android derives from the notifications themselves. iOS: the same
    `com.semay.semay/notifications` channel carries a `dismissChat` call, and
    `AppDelegate.swift` removes the delivered notifications whose
    `userInfo["chatId"]` matches (there is no local-notification plugin on
    iOS — the OS presents foreground pushes itself). The iOS app-icon NUMBER
    is separate and stays the server's job (`syncLauncherBadges`).
- **`push skipped: FCM disabled {reason, recipients, skipped}`** — logged (warn,
  at most once a minute) by every notification push path — chat, broadcast,
  order notice — when the server has no usable service account.
  `chats/service.ts` deliberately does not gate `sendChatPush` on
  `isPushEnabled()`: an early return there left chat, the highest-volume push,
  out of the count (the badge lookups it saves are the normal per-message
  ones). The one silent skip is the iOS badge-only correction after a read
  (`syncLauncherBadges`), which shows nothing even when it is sent. Until this
  line existed a push-less production was
  indistinguishable from a working one: the broadcast route answered
  `{sent: 25, failed: 0}`, the panel showed "Sent: 25", the inbox rows were
  there on next open, and no phone ever rang — exactly the "broadcast only
  visible after reopening, and silent" report. The boot line (§4) says the
  same thing once; this one says it every time it matters.
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

### 3c. Sessions last until logout

Both clients were forcing a re-login after roughly the 15-minute access-token
window (owner report, 2026-09) although refresh tokens nominally lasted 30
days. The access TTL was only the trigger; the session died because rotation
was strictly single-use and both clients turned *any* failed refresh into a
logout:

- **web-admin** refreshed per request with no coordination. A page plus its
  `/api/*` fetches, a hover-prefetch plus the click, or two tabs all POSTed
  `/auth/refresh` with the same cookie; rotation let one win and told the rest
  `SESSION_INVALID`, and `proxy.ts` answered that — and equally any 429, 5xx
  or network error — with a redirect to `/login` and cleared cookies. The
  dev-box request logs show the 200-then-401 pair on one token over and over.
- **mobile** treated 400/401/403 from `/auth/refresh` as final. A refresh whose
  response never arrived (15 s receive timeout, app suspended mid-request) left
  the phone holding a token the server had already retired; the next refresh
  was a replay, got 401, and the app logged out. `SecureSessionStore.save` also
  wrote the access token before the refresh token, so a kill between the two
  writes stranded the retired one.
- `REFRESH_TOKEN_TTL_DAYS=30`, with the reaper deleting on expiry, logged out
  any device idle for a month.

What holds now (`server/src/auth/session.ts`; pinned by
`tests/session.rotation.test.ts`):

| Rule | Mechanism |
|---|---|
| Rotation is still a compare-and-swap | `rotatedAt` flips null → timestamp for exactly one caller. `revokedAt` is kept for "logged out" so the two states cannot be confused |
| A just-rotated token is honoured for `REFRESH_REUSE_GRACE_SECONDS` (60 s) | The loser re-reads the row and is issued a live **sibling** pair in the same family (only the successor's *hash* is stored, so the identical pair cannot be re-sent). N concurrent refreshes with one token all succeed; a lost response heals on the next attempt |
| Past the grace, a replay is a replay | `401 SESSION_INVALID` for that token only — no family revocation, so a legitimately late retry can never sign a device out |
| Expiry slides | Every successor is issued with a fresh `REFRESH_TOKEN_TTL_DAYS` window (default 730): a token lapses only after two years *without use* |
| Logout ends the family | `familyId` links every row of a login; `/auth/logout` revokes them all, so a dangling sibling cannot outlive a sign-out. It takes the same rule as refresh: a live token, or one rotated inside the grace (a phone's Sign out racing its own refresh) ends the family; a token rotated past the grace or expired is a no-op (still 200) — a stale token, captured in transit or left in a backup, must not be able to end the owner's live session. Account deletion and the superadmin password change delete rows outright |
| A row without a family is its own | `familyId` has no database default (Prisma fills it). A build predating the column that is still serving after the migration was applied inserts `''` on a non-strict MySQL — for every user — and fails the INSERT on a strict one (`09_DEPLOYMENT.md` §12 gives the deploy order that avoids both). `session.ts` treats `''` as "root = this row" on rotation and logout, so such rows can never merge into one cross-user family |
| The reaper never deletes a live row | Only rows past `expiresAt`, or rotated/revoked more than 7 days ago (§5) |
| `/auth/refresh` and `/auth/logout` have their own limiter | `RATE_LIMIT_REFRESH_MAX_PER_MIN` (600/min per IP) instead of the 60/min OTP bucket — a refresh token is not guessable and costs no SMS, and a NAT'd cell or the panel's single server IP renews far more often than it sends OTPs |

The clients:

- **mobile** (`api_client.dart`, `session.dart`): a refresh is *rejected* — the
  only path to a logout — on an explicit `401 SESSION_INVALID`; a 429, 5xx,
  timeout or dropped socket is retried once after 2 s and otherwise left to the
  next request. The refresh token is persisted before the access token.
- **web-admin** (`src/lib/refresh.ts`, `src/proxy.ts`, `src/lib/apiClient.ts`):
  one in-flight refresh per token, shared by every concurrent request; a
  settled result is not kept (the server's grace covers a straggler still on
  the old cookie, and a remembered pair would keep being re-issued for a
  minute after Logout had revoked it). The proxy clears the cookies only on the
  API's `401 SESSION_INVALID` — by error code, never on a bare 401 or 400 from
  whatever sits in front of the API — or a refreshed token that is no longer
  superadmin, and answers an unreachable API with a 503 that retries itself,
  cookies intact. The refresh cookie is issued for 400 days — the browser cap — on
  every refresh. Superadmin login mints its pair through the same
  `createSession`, so the panel follows exactly these rules.

What this trades away: a refresh token on a lost, unlocked phone stays valid
until that device signs out, the account is deleted, or (superadmin) the
password is changed — there is no per-device "sign out everywhere" for ordinary
users yet. The grace is, by design, a 60-second replay window for a token
captured in transit; rotation plus the 15-minute access TTL keep the exposure
to that window. A refresh response lost for good (the phone never retried
inside the grace) leaves a live row whose token nobody holds; the phone's own
Sign out cannot reach it — by then its token is past the grace and a no-op —
so it lapses only with the two-year expiry. Unusable, and bounded to one row
per lost response.

### 3d. Bus health: a dead Redis is loud, degraded, and never a frozen thread

The realtime bus (`realtime/bus.ts`) has two states worth knowing about beyond
"Redis or not":

- **Live** — `REDIS_URL` set, both connections `ready`, every subscribed
  channel confirmed. Publishes go to Redis only; the echo on this process's own
  subscriber connection performs local delivery, exactly once per socket.
- **Degraded** — `REDIS_URL` set but Redis unreachable, flapping, or just
  restarted and not yet re-subscribed. Publishes are delivered **in-process**
  (counted as `droppedPublishes`): complete for a single process, partial for
  a cluster (sockets on other workers miss them). ioredis's offline queue is
  disabled, so nothing piles up in memory to burst out — or not — later.

The transitions are the part that used to be missing:

- **Boot** probes Redis for up to 5 s, **without holding the listener shut**.
  Unreachable → an error-level line, `realtime: REDIS_URL is set but Redis is
  unreachable — falling back to in-process delivery…`, with `redis: host:port`.
  The single-process server boots degraded (it still serves every one of its
  own sockets correctly). The probe is deliberately NOT awaited before
  `app.listen()` (`index.ts`): while it was, an unreachable Redis put its whole
  5 s in front of every start — measured, "Server listening" 5.03 s after boot
  against a blackholed `REDIS_URL` — so a Redis outage was also a deploy
  outage, for a verdict that gates nothing (the process boots degraded either
  way and `publish()` always serves its own sockets first).
  **`start:cluster` still awaits it and refuses to fork**: there it is the
  fail-closed gate, the primary serves no traffic, and a degraded cluster is
  exactly the silent loss requirement §2.1 exists to prevent.
- **Drop** → warn `Redis connection lost`; each refused reconnect → error
  `Redis error` (once per distinct message, then once a minute — ioredis
  retries forever with a 1 s → 30 s backoff). **Recovery** → warn `Redis
  reconnected`, with how long it was down and how many publishes stayed
  local. Every channel with a listener is re-`SUBSCRIBE`d on recovery: ioredis
  only re-subscribes channels it had confirmed before the drop, so one whose
  `SUBSCRIBE` was refused while Redis was down would otherwise never be
  subscribed at all.
- **Two health paths, because they answer different questions.**
  `/health/ready` answers `{ ok, db, degraded, realtime, bus: { mode, ready,
  droppedPublishes } }` and its **status code follows the database only**.
  `/health/realtime` answers `{ ok, required, degraded, bus }` and is the one
  that **fails closed** — 503 after 30 s of no bus where Redis is *required*
  (a cluster worker — a re-forked worker boots degraded rather than
  crash-looping — or `REDIS_REQUIRED=true`, one process per machine sharing a
  Redis). 30 s so a Redis restart is a blip, not a flap.

  The fail-closed verdict used to live on `/health/ready`, and that was wrong
  in the exact topology §2 recommends: several single-process boxes behind a
  load balancer sharing ONE Redis all cross the threshold at the same instant,
  so the balancer is left with **zero** healthy backends and login, feed,
  stores, orders, media and chat REST go dark — every one of which works
  perfectly during a Redis outage. Only cross-process realtime fan-out does
  not. So: the HTTP pool's health check points at `/health/ready`, the
  WebSocket pool's (and alerting) at `/health/realtime`, and a Redis outage
  costs realtime instead of everything.

  The Redis host:port and the raw ioredis message (`busHealth().lastError` /
  `lastErrorAt`) are deliberately NOT on either body — neither endpoint takes
  authentication. They are in the `realtime: Redis error` log line instead
  (`redis:` is the host:port, `err:` the reason).
- **The sockets already attached go too — and this is the half that matters.**
  A health check alone is half a fix, and the missing half was the reported
  defect itself: taking a worker out of rotation stops NEW connections landing
  on it, but does not close the WebSockets it is already holding — and those
  are the phones with a chat thread open. They cannot tell either: the
  client's stall rule measures silence only while a subscribe is outstanding
  (§3a), and on a worker whose bus dies *after* its snapshots went out, nothing
  is outstanding, so it sits on `connected` with a frozen thread and no
  "Connecting…" — forever. So the same condition that turns `/health/realtime`
  503 (`isBusUnavailable()`, one definition in `bus.ts` for both) also makes
  the gateway sweep its own sockets every 5 s: each is closed with
  **4503 `BUS_UNAVAILABLE`**, and a
  subscribe arriving in that state is answered `SUBSCRIBE_FAILED` rather than
  served a snapshot that will never move. The client reconnects through its
  backoff, lands on a worker that works, and shows "Connecting…" until it
  does. Single-process without `REDIS_REQUIRED` is untouched — there is no
  other worker to miss, and `publish()` always delivers locally first.
- **Subscribe never hangs.** The bus bounds a `SUBSCRIBE` at 3 s and does not
  wait at all on a connection ioredis is backing off from, so the gateway's
  snapshot goes out within milliseconds against a dead Redis; the gateway
  bounds the whole authorize → subscribe → snapshot at 10 s and sends
  `{type:"error", error:"SUBSCRIBE_FAILED"}` on any failure (it used to send
  nothing), which the client treats as "stalled: reconnect" (§3a).
  All concurrent waits on one connection attempt share **one** promise and
  attach **no** listener to the ioredis client. Each used to attach its own
  pair of `events.once` handlers — ~6 listeners per in-flight subscribe on the
  one shared client — so a Redis that is reachable and HUNG (a firewall DROP, a
  swapping box: the precise case this design exists for) printed
  `MaxListenersExceededWarning` into the log an operator was reading, and cost
  O(N²) in `EventEmitter` array churn at the scale §2 plans for. Reproduced on
  a booted server: one socket, 12 channels in a burst against a blackholed
  `REDIS_URL`, three warning lines. Pinned by
  `tests/realtime.bus-waiter.test.ts`. `closeBus()` bounds its `QUIT` for the
  same reason — a hung Redis must not hold SIGTERM open.
- **What one socket may cost is bounded** (`realtime/gateway.ts`). At most
  **256 channels held at a time** — a further subscribe is answered
  `{error:"CHANNEL_LIMIT"}`, a per-channel verdict the client handles like
  `FORBIDDEN` rather than tearing the socket down — and a **token bucket of 120
  frames refilling at 30/s**, past which the socket is closed with **4429
  `TOO_MANY_FRAMES`**. Neither was bounded before: `ws`'s 4 KiB `maxPayload`
  (`app.ts`) caps a frame's size and nothing else, while every frame is
  `JSON.parse`d synchronously inside ws's receiver and may carry a subscribe
  (an authorize plus a snapshot — 200 rows for a chat thread). Both ceilings
  are far above anything the app does: the client refcounts channels and
  unsubscribes when the last listener goes, and every consumer is autoDispose,
  so a socket holds the chat list, the open threads and what is on screen —
  tens. Pinned over a real socket in `tests/realtime.gateway.test.ts`.

Pinned by `tests/chat.liveness.test.ts` over a real listener and real sockets:
20 upserts live across two access-token expiries (TTL 3 s — expiry across an
open socket was the first suspect, and is not it); a Redis outage mid-stream,
simulated through a killable TCP relay in front of the real Redis, loses no
message and resumes over Redis; a `REDIS_URL` pointing at a closed port gets
its snapshot in under 3 s, live upserts, and a `bus.ready:false` readiness
body; `REDIS_REQUIRED` flips `/health/realtime` to 503 after the grace period
*while `/health/ready` keeps answering 200*, and the same worker then refuses a
new subscribe with `SUBSCRIBE_FAILED` and closes the socket it was already
holding with 4503. The gateway's `SUBSCRIBE_FAILED` frame, the per-socket
channel ceiling and frame budget, and the `receipts` roll-up (including that a
receipt which stamped no message publishes no frame at all) are covered in
`tests/realtime.gateway.test.ts`; the shared connection waiter in
`tests/realtime.bus-waiter.test.ts`.

## 4. Logging

Newline-delimited JSON to `LOG_DIR/app.<date>.log`, rotated daily and pruned to
`LOG_RETENTION_DAYS` files (default 14) so disk use is bounded. Console output is
pretty-printed outside production only. `LOG_LEVEL` controls verbosity.

Boot logs three things worth alerting on:

- `FCM push is DISABLED` — the service-account file is missing, unreadable, not
  a service-account key, or belongs to a different Firebase project than
  `FIREBASE_PROJECT_ID` (the reason names both ids), so no push will be
  delivered. The API otherwise runs normally by design. Its counterpart,
  `FCM push enabled`, logs the project and sender email so they can be checked
  against the app's `firebase_options.dart` (`09_DEPLOYMENT.md` §5d).
- `realtime: in-process only` — `REDIS_URL` is unset. Fine for one process,
  **wrong for more than one** (see §2.1).
- `realtime: REDIS_URL is set but Redis is unreachable` (error level) — the
  process delivers in-process only (§3d): fine for one process, an outage for
  a cluster or a second machine. While it lasts the log carries
  `realtime: Redis error` (rate-limited); `realtime: Redis reconnected` marks
  the recovery. `start:cluster` does not log this — it refuses to start.

## 5. Scheduled maintenance

`server/src/maintenance.ts` runs hourly in every process, but a MySQL advisory
lock (`GET_LOCK`) means exactly one actually reaps per tick — correct across both
workers and machines, unlike a "only worker 1" convention.

| Reaped | Rule | Guard |
|---|---|---|
| Expired stories + their media files | `expiresAt` older than a 1h grace window | Grace window means a viewer mid-playback at the 24h boundary is never cut off |
| Sessions | past their sliding expiry (`REFRESH_TOKEN_TTL_DAYS` of no use), or rotated away / revoked more than 7 days ago | A live row is never deleted whatever its age — sessions last until logout (§3c). Retired rows are kept far longer than the reuse grace so a replayed token gets an explicit 401 rather than silently missing |
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
  the superadmin login/password routes. `/auth/refresh` and `/auth/logout`
  have their own, wider bucket (`RATE_LIMIT_REFRESH_MAX_PER_MIN`, 600/min):
  sharing the 60/min cap meant a busy carrier NAT — or the one Next.js server
  IP every admin-panel refresh comes from — got 429 on routine renewals (§3c).
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

## 6f. The public share pages — the API's only unauthenticated HTML

A share button in the app produces `https://semaycollection.com/p/<postId>`
(`/r/` reel, `/s/` store). Whoever receives it may have no account and no app,
so five routes are served at the **root**, outside `/api/v1`, with **no
authentication at all** (`server/src/share/routes.ts`, registered in `app.ts`
after the rate limiter and before the API groups):

| Route | Returns |
|---|---|
| `GET /p/:id`, `/r/:id`, `/s/:id` (and each with a trailing slash) | `text/html; charset=utf-8` — the share page |
| `GET /share-assets/semay.png` | the 1200×630 `og:image`, read into memory once at boot |
| `GET /.well-known/assetlinks.json` | `application/json` — Android App Links |
| `GET /.well-known/apple-app-site-association` | `application/json`, **no file extension** — iOS Universal Links; **404 while `SHARE_IOS_APP_ID` is empty**, see below |

Both spellings of each page route are registered deliberately. Fastify's
`ignoreTrailingSlash` is false, so `/p/<id>/` would otherwise miss them and fall
to the API-wide JSON not-found handler — a person in a browser would be shown
`{"error":"NOT_FOUND"}`. And `/p/<id>/` is genuinely reachable: the
AndroidManifest `pathPrefix` claims it and the app's own parser accepts it, so
every URL those two accept has to be answered here.

**What the page exposes: nothing from the database.** `SHARE_PAGE_MODE` is
`generic` and that is the only supported value. The page renders the same copy
for every id of a given kind — a headline, an "Open in SeMay" button, and the
store links — and `share/routes.ts` imports neither Prisma nor anything under
`auth/`. Two properties follow, and both are the reason the mode exists:

- **No existence oracle.** A stranger cannot use a share link to learn whether a
  post or store id exists, whether a store is active, or anything about either.
  A "content" page that rendered the post would leak exactly that, for free, to
  anyone who can guess or enumerate an id.
- **No unauthenticated DB load.** These are the only routes a stranger holding a
  link can reach; none of them can put a query in front of MySQL.

If a content variant is ever wanted, it needs its own review: `Post.caption`,
`Post.price`, the media URLs and `Store.name/avatarUrl/coverUrl/tagline` would
become public to anyone with the link, and `Store.phone`, `Store.address`,
`Store.geoLat/geoLng`, `Store.createdById`, `Store.leaderboardOrder`,
`Store.campaign*`, every counter and every `User` field must stay out of it.
`tests/authz.matrix.test.ts` ("public share routes") already asserts a real
store's phone, address, name and creator id appear nowhere in the page.

Other properties, each pinned by `tests/share.pages.test.ts`:

- **Reachable with no token, and unchanged with one.** No role sees a different
  page; a garbage `Authorization` header is ignored rather than rejected,
  because no auth code path runs at all.
- **Own rate limit.** `RATE_LIMIT_SHARE_MAX_PER_MIN` (default 120/min per IP) on
  top of the global 3000, applied per route with the `config.rateLimit` idiom
  from `auth/routes.ts`. The global cap is deliberately generous for carrier
  NAT; that generosity is wrong for a public HTML surface a stranger can
  hammer. Verified against a booted server, since the limiter is disabled under
  `NODE_ENV=test`. **The 429 body is an HTML page too**, in the reader's
  language and carrying the store buttons — `@fastify/rate-limit` *throws* what
  its `errorResponseBuilder` returns, so the JSON default cannot be replaced at
  the route; `share/routes.ts` sets an error handler scoped to its own plugin
  instead (the rest of the API keeps `lib/errors.ts` untouched). This matters
  because Turkmen mobile traffic sits behind heavy carrier NAT: a link
  forwarded into a large group chat can put several genuine recipients into one
  IP bucket within a minute.
- **Own CSP, tightened per reply — helmet's global policy is not loosened.** The
  page carries no `<script>` and no inline handler, and says so:
  `default-src 'none'; img-src 'self' https: data:; style-src 'unsafe-inline';
  base-uri 'none'; form-action 'none'; frame-ancestors 'none'`. helmet's default
  allows `script-src 'self'`, which would be enough to run an injected tag if
  escaping ever broke; every interpolated value is HTML-escaped as the primary
  defense and this CSP is the second. Set with `reply.header` on these replies
  only, so the rest of the API keeps helmet's defaults untouched.
- **Ids are shape-validated** as UUIDs. Anything else gets a 404 **HTML** page
  (`Cache-Control: no-store`), not the API's `{"error":"NOT_FOUND"}` JSON — the
  reader is a person in a browser. `mobile/lib/core/share_links.dart` enforces
  the **same** UUID shape, and that parity is load-bearing: once App Links
  verify, a hand-typed `…/p/abc123` is intercepted by the app, so a looser
  client parser would push a detail screen for a post that cannot exist instead
  of letting the browser show the page that explains the link is wrong.
- **Cacheable, and `Vary`s on what the body depends on**: `User-Agent` (the
  Open button is `intent://…` on Android and `semay://open/…` everywhere else)
  and `Accept-Language` (tk default, ru/en; `?lang=` overrides). A shared cache
  that ignored those would hand an iPhone Android's intent URL.
- **`noindex`.** Every page is the same generic copy; indexing one per post id
  would be thousands of duplicates.

**Why the well-known files matter operationally.** The app ships an
`autoVerify="true"` https intent-filter for both hosts, and Android fetches
`assetlinks.json` at install/update to decide. Until `SHARE_ANDROID_CERT_SHA256`
is set to the **Play App Signing** certificate's fingerprint (not the upload
key), the document is served empty-but-valid, verification reports `none`, and a
tapped https link opens the browser instead of the app — with no other symptom.

iOS has no associated-domains entitlement yet by decision (portal work), so
`SHARE_IOS_APP_ID` is empty and `/.well-known/apple-app-site-association`
answers **404, not an empty document**. That asymmetry with the Android file is
deliberate: Apple does not fetch the AASA from this origin, it fetches through
`app-site-association.cdn-apple.com` and **caches** the result, so publishing
`{"applinks":{"apps":[],"details":[]}}` today would leave the CDN answering
"this site delegates nothing" for days after the entitlement and
`SHARE_IOS_APP_ID` finally land — Universal Links would look broken with no
error anywhere. A 404 is not cached as a negative delegation the same way and
makes the missing configuration visible in the operator's own curl. The Android
half keeps its 200 + empty array, where an empty document merely fails
verification, harmlessly.

**In both states the share page's own "Open in SeMay" button still opens the
app**, which is why that button — not link verification — is the guaranteed
path in. What it does for a recipient **without** the app differs by platform:

- **Android.** The button is an `intent://` URL carrying
  `S.browser_fallback_url`, which is where Chrome goes when it cannot resolve
  the package — i.e. exactly the no-app case. That fallback is
  **`SHARE_PLAY_URL`** whenever it is configured, per the owner decision
  ("iPhone → App Store, Android → Google Play"). It previously pointed at the
  share page itself, which made the primary button a silent reload for its only
  audience. With `SHARE_PLAY_URL` empty ("no listing yet" — the page then shows
  a `Google Play · Ýakynda` badge instead of a link) the fallback stays the
  canonical page URL: staying put beats Chrome's own Play-Store-for-package
  redirect to a listing nobody has confirmed exists.
- **iPhone.** The button is the bare `semay://` scheme, which is the *only*
  thing that can open the app before the entitlement exists. On an iPhone
  **without** the app, Safari answers an unhandled scheme with a modal
  *"Safari cannot open the page because the address is invalid"*. No JS-free
  page can detect that in advance, and the page is deliberately script-free, so
  this is accepted and mitigated by the App Store button below it. Expect it on
  device; it is not a regression.

Both `SHARE_PLAY_URL` and `SHARE_APPSTORE_URL` **default to empty**, and empty
renders the "coming soon" badge. The symmetry is intentional: whether either
listing is published is an owner fact, not something to assume in a config
default — a Play 404 is strictly worse for a recipient than an honest
`Ýakynda`.

nginx needs no change: `location /` already proxies these paths to the API, for
`semaycollection.com` and `www.` alike.

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
is `ORDER BY createdAt DESC LIMIT/OFFSET` over **every** post type (reels
interleave with photos as inline video cards, since 2026-09), with no `WHERE`
unless the optional `?type=` filter is given. That unfiltered walk is served
directly by `posts_createdAt_idx`: `EXPLAIN` on the dev box shows
`type=index, key=posts_createdAt_idx, rows=20, Using index`, no filesort —
strictly cheaper than the query the index was added for.

Why the index exists: `/feed` originally filtered `type IN ('image','carousel')`.
The `(type, createdAt)` index **cannot** serve that shape — it orders by
`createdAt` only *within* one type, so spanning two made MariaDB abandon the
index entirely. Measured on a 300k-post scratch database (never the live one):

| | plan | time |
|---|---|---|
| before | `ALL` — full scan of 293k rows + `Using filesort` | **135 ms** |
| after `@@index([createdAt])` | `rows: 20`, no filesort | **0.2 ms** |

~650× faster, and the old cost grew linearly with total post count. The type
filter has since been dropped (it was the regression that hid reels from the
feed), but the index stays: it is the one that makes the unfiltered walk a
20-row read. `/feed?type=reel`, `/reels` (single type) and
`/stores/:id/posts` use the `(type, createdAt)` / `(storeId, createdAt)`
indexes and were left alone. The §7 load-test numbers below were measured with
the old `IN` filter; the unfiltered query does less work, so they are
conservative.

**Client-side cost of reels in the feed (media bandwidth, not MySQL):** a feed
reel tile plays from a whole-file download (`MediaCache`, so a rewatch is served
from disk — the same treatment as the Reels tab and the story viewer), and a reel
may be up to 100 MB. The app's home feed is a `ListView` that builds cards past
the viewport, so a tile that fetched on mount pulled every reel the user
scrolled anywhere near, in full, on mobile data. The fetch therefore starts only
when the tile first qualifies to play (>60% on screen, its tab settled, app in
the foreground — `_FeedReelPlayer._syncPlayback` in
`mobile/lib/features/shared/widgets/post_card.dart`), and a failed fetch keeps
the poster and retries on the next scroll-in. Progressive streaming
(`VideoPlayerController.networkUrl`) for the inline tile would cut this further
at the cost of the instant rewatch and a second download when the full-screen
player opens; not done — an owner call on bandwidth vs. rewatch.

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

**3. Transactions the pool refused to START were not retried** (found later,
while making the test suite deterministic; same class as 1, one layer out).
`withRetry` only re-ran `P2034` — a transaction MySQL rolled back. It did not
re-run one that never began: when every pooled connection is busy, Prisma gives
up after `maxWait` (2 s) and raises `P2028 "Unable to start a transaction in the
given time."`, and `P2024` when `pool_timeout` elapses fetching a connection.
Defect 1's own fix makes this *more* likely, not less — the up-front
`SELECT … FOR UPDATE` is what turns a deadlock into a queue, and every waiter in
that queue holds its connection while it waits. So the same hot post that used
to deadlock now parks 15 connections on one row, and caller 16 gets a 500 for
nothing but being popular. `POST /auth/refresh` had the sharper version: N
refreshes on one token queue on one `sessions` row, and `rotateSession` had no
retry wrapper at all, so the loser answered **500 — which the app treats as a
failed refresh and turns into a logout**.

Fixed in `server/src/lib/withRetry.ts`: both acquire failures are retried, on
their own small budget (3 attempts — each has already cost its `maxWait`, and
eight would turn a saturated pool into a 16 s request). Retrying is safe
precisely because *no statement of the transaction reached the database*; the
other `P2028`, an interactive-transaction execution timeout, is matched out by
message and still propagates. `rotateSession` (`auth/session.ts`) and the
maintenance reaper's bulk deletes (`maintenance.ts` — `stories`, `sessions` and
`otp_codes`, every one of them contending with live traffic, and an unretried
rollback there aborted the *whole* cycle including the media sweep for an hour)
now use `withRetry` like every other contended write. Pinned by
`server/tests/tx.retry.test.ts`.

Reproduced and verified by loading the box deliberately (12 busy CPU threads
alongside `npm test`): before, 3 files / 5 tests red, every one of them
`Unable to start a transaction in the given time`; after, 37 files green under
the same load.

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
  `requireFreshAuth`, revocation on account deletion) needed to change. The
  panel session therefore follows §3c like a phone does: it lasts until the
  Logout button, silently refreshed by `web-admin/src/proxy.ts` (single-flight)
  behind a 400-day `refresh_token` cookie, and the panel ends it only on the
  API's own `SESSION_INVALID` — never over a 429, a 5xx or an API restart.

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
