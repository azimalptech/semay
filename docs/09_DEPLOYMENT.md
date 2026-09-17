# 09 — Deployment

Full, start-to-finish instructions for standing up the server — from a bare
Windows machine to a running, backed-up, auto-restarting API. `07_MIGRATION.md`
is the history of how the backend got here; `08_OPERATIONS.md` is the
reasoning behind every scaling/hardening decision. This doc is the checklist —
read the other two for *why*, this one for *what to type*.

Current deployment target is a single Windows box (XAMPP MariaDB + the API as
a Windows service). Steps that assume Windows are marked; the app itself is
platform-agnostic Node/Fastify and would run the same way on Linux with
systemd/pm2 in place of the Windows-service steps.

## 1. Fresh-machine prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Node.js | ≥ 20.6.0 | `server/package.json` engines field. Needed for native `--env-file` support. |
| MySQL / MariaDB | MySQL 8, or MariaDB 10.4+ (XAMPP) | This box runs XAMPP's bundled MariaDB 10.4. |
| Redis | any recent version | Only required once you run more than one process (`start:cluster`). Optional for single-process/small deployments. |
| git | — | |

Installing each on a clean Windows machine:

```powershell
# Node.js LTS and git — winget ships with Windows 10/11
winget install -e --id OpenJS.NodeJS.LTS
winget install -e --id Git.Git
# open a new shell afterwards so PATH picks both up
node -v && git --version
```

**MySQL/MariaDB** — the simplest path on Windows is
[XAMPP](https://www.apachefriends.org/) (bundles Apache + MariaDB with a
service-manageable control panel); install it, then enable the MySQL service
to auto-start (XAMPP Control Panel → Config → "Autostart" for MySQL, or install
it as a proper Windows service — see §5). A standalone MySQL 8 Community
Server install works identically; only the config file path in §5 changes.

**Redis** — has no first-party Windows build. Options, in order of least
friction: [Memurai](https://www.memurai.com/) (Redis-compatible, installs as a
native Windows service — closest drop-in), Redis under WSL2, or a Redis
container via Docker Desktop. Skip entirely if you're only ever running one
API process (`npm start`, not `start:cluster`).

## 2. Get the code

```bash
git clone https://github.com/azimalptech/semay.git
cd semay/server
```

## 3. First-time app setup

```bash
cp .env.example .env        # fill in values — see §4
npm install
npm run prisma:generate
npm run prisma:migrate      # dev: creates tables against DATABASE_URL, prompts for a migration name
npm run dev                 # sanity check — tsx watch on src/index.ts
curl http://localhost:8080/health   # {"ok":true,...}
```

For a machine that will run the built service instead of `dev`, skip straight
to §6 once `.env` is filled in and migrations are applied.

## 4. Environment variables

Full reference with rationale lives in `server/.env.example` — copy it, don't
retype it. The ones worth calling out specifically:

- **`DATABASE_URL`** — include `?connection_limit=N&pool_timeout=20`. The capacity
  math (`CLUSTER_WORKERS × connection_limit` must stay under MySQL's
  `max_connections`) is in `08_OPERATIONS.md` §2. `cluster.ts` refuses to boot if
  this doesn't fit — it will tell you the three ways to fix it.
- **`JWT_SECRET`** — generate with:
  ```bash
  node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
  ```
  Must be identical in `web-admin/.env.local` — the panel verifies tokens this
  server mints, it doesn't mint its own. Rotating it logs everyone's access
  token out; refresh tokens survive, so clients recover on their own.
- **`ACCESS_TOKEN_TTL_SECONDS` / `REFRESH_TOKEN_TTL_DAYS` / `REFRESH_REUSE_GRACE_SECONDS`** —
  sessions last until logout (`08_OPERATIONS.md` §3c). The access JWT is
  short-lived (900 s) and renewed silently. The refresh token expires only
  after `REFRESH_TOKEN_TTL_DAYS` (default 730) *without use* — every refresh
  re-issues it with a fresh window — so this bounds abandoned devices, not how
  often anyone logs in. A refresh token already rotated away is still accepted
  for `REFRESH_REUSE_GRACE_SECONDS` (default 60); lowering it brings back the
  lost-response logout, and 0 disables the grace entirely. **An existing
  `.env` that still says `REFRESH_TOKEN_TTL_DAYS=30` must be changed to 730 (or
  the line removed) when this ships** — the file value wins over the default,
  and 30 silently reinstates the monthly logout. Every `.env` written before
  2026-09 says 30 (the dev box's did); it is a hard gate in §14.
- **`RATE_LIMIT_REFRESH_MAX_PER_MIN`** — per-IP cap for `/auth/refresh` and
  `/auth/logout` (default 600), separate from the 60/min OTP bucket: the
  panel's single server IP and a NAT'd cell renew far more often than they
  send OTPs.
- **`SMS_GATEWAY_URL` / `_USER` / `_PASSWORD`** — required unless
  `OTP_DEV_MODE=true`. Points at a capcom6/sms-gate.app gateway. **Which URL to
  use depends on where the API runs** — see §5b; a remote API must use the Cloud
  relay, not the phone's LAN address.
- **`OTP_DEV_MODE`** — `true` echoes the OTP code in the `/auth/otp/send`
  response instead of sending a real SMS. Convenient for local dev; must be
  `false` before anyone but you can reach the server.
- **`MEDIA_DIR` / `MEDIA_PUBLIC_BASE_URL`** — local disk, not object storage.
  Must resolve consistently if you front it with a reverse proxy (§9).
- **`REDIS_URL` / `REDIS_REQUIRED` / `CLUSTER_WORKERS`** — leave `REDIS_URL`
  empty for one process. The moment you run `start:cluster` or more than one
  machine, `REDIS_URL` is required — without it, realtime messages published
  on one worker never reach sockets owned by another. **Set is not the same as
  reachable.** A `REDIS_URL` pointing at a Redis that is not running (the dev
  `.env` copied to a box without the service; the service not set to
  auto-start after a reboot) used to be completely silent: the boot line said
  "Redis pub-sub", `/health/ready` said ok, and every phone's chat quietly
  stopped updating until the app was reopened. Now the single-process server
  boots but logs an error naming the host and delivers in-process
  (`/health/ready` shows `degraded:true`, `bus.ready:false`); `start:cluster`
  refuses to fork. Several single-process machines behind a load balancer:
  set `REDIS_REQUIRED=true`. After 30 s without the bus that box stops serving
  **realtime** — the gateway refuses new subscribes and closes the sockets it
  is holding, so phones reconnect to one that works, and `GET /health/realtime`
  turns 503 for the WebSocket upstream's health check. **`/health/ready` stays
  200 on purpose**: login, feed, stores, orders, media and chat REST all work
  perfectly during a Redis outage, and every box sharing one Redis crosses that
  threshold at the same instant — failing readiness would leave the balancer
  with zero healthy backends and take the whole API down over a dependency most
  of it does not use (`08_OPERATIONS.md` §3d). Point the HTTP pool's health
  check at `/health/ready` and the WebSocket pool's at `/health/realtime`. Run
  Redis as an auto-starting service like MySQL (§5).
- **`SHARE_*`** — the public share pages (§5e; what they expose and why,
  `08_OPERATIONS.md` §6f). All have working defaults; two matter on a real
  deploy:
  - **`SHARE_ANDROID_CERT_SHA256`** — comma-separated SHA-256 fingerprints
    (colon-separated uppercase hex, as `keytool` prints them) of the
    certificate the **installed** app is signed with. With Play App Signing
    that is the *app signing* key Play shows, **not** the upload key. Empty
    (the default) serves a valid but empty `assetlinks.json`, so Android App
    Links can never verify and a tapped link opens the browser page instead of
    the app — no other symptom, so this one is easy to miss.
  - **`SHARE_APPSTORE_URL`** / **`SHARE_PLAY_URL`** — where a recipient without
    the app is sent. **Both default to empty**, and empty renders a non-link
    "coming soon" badge (`Ýakynda` / `Скоро`). Set each one only once *that*
    listing is actually published: a store URL for a listing that does not
    exist sends the recipient to a store 404, which is worse than the badge.
    `SHARE_PLAY_URL` does double duty — it is also the Android "Open in SeMay"
    button's `S.browser_fallback_url`, i.e. where Chrome goes when the app is
    not installed (§5e).
  - `SHARE_IOS_APP_ID` (`<TEAM ID>.com.semay.semay`) stays empty until the app
    ships the associated-domains entitlement — see §5e. While it is empty
    `/.well-known/apple-app-site-association` answers **404 by design**, not an
    empty document (Apple's CDN caches what it fetches; §5e explains). Setting
    it is what turns that route on. `SHARE_PAGE_MODE` (`generic`, the only
    value), `SHARE_PUBLIC_BASE_URL` (empty = derived from
    `MEDIA_PUBLIC_BASE_URL`'s origin; **origin only — any path is stripped**,
    since the variable it is copied from ends in `/media`),
    `RATE_LIMIT_SHARE_MAX_PER_MIN` (120) and `SHARE_ANDROID_PACKAGE` are
    correct as they ship.

## 5. Database

- Import/create the `semay` schema via `npm run prisma:migrate` (dev) or
  `npm run prisma:deploy` (applies existing migrations without prompting or
  generating new ones — use this on a server, not `migrate dev`).
- Run MySQL/MariaDB as an auto-starting service so a reboot doesn't take the
  app down with it. On XAMPP/Windows this is the `mysql` service (Services
  panel, startup type Automatic).
- **Tune it before real traffic.** Stock XAMPP defaults (`innodb_buffer_pool_size=16M`,
  `max_connections=151`) are far too small. Full before/after table and
  reasoning: `08_OPERATIONS.md` §7 "MySQL configuration". Config file is
  `C:/xampp/mysql/bin/my.ini`; changes need a restart:
  ```bat
  net stop mysql && net start mysql
  mysql -u root -e "SELECT @@innodb_buffer_pool_size, @@max_connections;"
  ```

## 5b. SMS gateway (OTP delivery)

OTP codes go through **our own relay** — `sms-gateway/` in this repo — talking
to Android handsets running `sms-gateway/android/`. Full design notes in
`sms-gateway/README.md`.

**Why not sms-gate.app.** That was the original integration and it cannot work
from here: `api.sms-gate.app` is unreachable from Turkmen networks. Measured
from the gateway handset itself, on the same Wi-Fi, at the same moment:

| Host | Result |
|---|---|
| `api.sms-gate.app` | **100% packet loss** |
| `semaycollection.com` | 0% loss, 13ms |
| `google.com`, `fcm.googleapis.com` | 0% loss |

So it is that specific domain being filtered, not general censorship, and no
amount of retrying or reconfiguring the cloud relay fixes it. Messages sat at
`Pending` forever. Our relay runs on a host the handset can actually reach.

### Deploy the relay

```bash
cd /opt/semay/app/sms-gateway
cp .env.example .env          # fill in — see below
npm install
npm run prisma:generate
npm run prisma:deploy
npm run build

sudo cp deploy/semay-sms-gateway.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now semay-sms-gateway
curl http://127.0.0.1:8081/health          # {"ok":true,...}
```

Create its database first — it is deliberately separate from `semay`, so the
app's migrations and the relay's never block each other:

```sql
CREATE DATABASE semay_sms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

Then expose it through nginx (`deploy/nginx-sms.conf`, paste into the existing
443 server block) and reload. **Note the `proxy_read_timeout`** in that file:
it must exceed the relay's 25s long-poll hold or the HTTP fallback transport
gets killed mid-hold.

### Point the API at it

In `server/.env` — no code change, `sms.ts` already speaks this protocol:

```ini
SMS_GATEWAY_URL="https://semaycollection.com/sms/3rdparty/v1"
SMS_GATEWAY_USER="semay-api"
SMS_GATEWAY_PASSWORD="<API_PASSWORD from sms-gateway/.env>"
OTP_DEV_MODE=false
```

`OTP_DEV_MODE=false` is what switches `sms.ts` from the dev logger to the real
gateway. **Leaving it true is an account-takeover hole, not a nuisance**:
`/auth/otp/send` returns the code in its own response body, so anyone who can
reach the API can log in as anyone. The server refuses to boot if it is false
while any gateway value is blank, so a half-configured gateway fails loudly at
startup instead of silently failing every login.

Restart the API afterwards — env vars are read once, at boot. A `.env` edit
with no restart changes nothing, and looks exactly like the edit not working.

### Register each sender handset

```bash
cd /opt/semay/app/sms-gateway
npm run device:add -- --name "samsung-a16-sim1"      # prints a token ONCE
```

Install `sms-gateway/android` on the phone, enter `https://semaycollection.com/sms`
plus that token, grant SMS + phone permissions, and press Save & start.

**Then disable battery optimisation for it.** This is not optional. A partial
wake lock keeps the CPU alive but Android still suspends *network* for apps
that are not exempt, so the app keeps showing "Connected" while its socket has
been dead for an hour — which is precisely how the previous gateway hid an
outage. The app appends a warning to its own status until the exemption is
granted.

Capacity scales by SIM: one dual-SIM handset is two senders, N handsets are 2N.
The relay round-robins across every SIM that is reachable and under its rate
caps.

### Verify

```bash
# who is reachable, and over which transport
curl -u "semay-api:<API_PASSWORD>" https://semaycollection.com/sms/3rdparty/v1/device

# send a real one (goes to a real phone — use your own number)
curl -u "semay-api:<API_PASSWORD>" -H "Content-Type: application/json" \
  -d '{"phoneNumbers":["+993XXXXXXXX"],"message":"SeMay test"}' \
  https://semaycollection.com/sms/3rdparty/v1/message
```

A handset should show `online: true` with `transport: "websocket"` or
`"polling"` — both are healthy. `"offline"` means it has neither a socket nor a
recent poll, and no OTP will reach it.

> Do not commit real gateway credentials or device tokens. `server/.env` and
> `sms-gateway/.env` are both gitignored; keep them there and nowhere else.

## 5c. Accounts

A freshly migrated database has no accounts at all, and the superadmin is the
one account that cannot bootstrap itself: every other role signs in with
phone+OTP, which self-provisions on first verify, while the panel is
password-only and change-password demands the *current* password. So a new
deployment comes up with a panel nobody can log into.

```bash
cd server
npm run superadmin -- --phone +99362936253      # prompts twice, echo off
```

Minimum 12 characters, enforced (`changePasswordSchema`). The script bumps
`claimsVersion` and revokes existing sessions, so a role or password change
takes effect immediately rather than when tokens happen to expire.

### Roles

```bash
node --env-file=.env scripts/set-role.mjs --phone +993… --role user|admin|superadmin
```

Refuses to demote the last superadmin, since that locks everyone out of the
panel with no way back except running `superadmin` again on the box.

**A superadmin can log in with OTP alone.** The password guards only the web
panel; OTP mints a token carrying the account's real role, so anyone holding
that SIM has full superadmin API access. Audit periodically:

```bash
node --env-file=.env -e 'import("@prisma/client").then(async({PrismaClient})=>{const p=new PrismaClient();console.table(await p.user.findMany({where:{role:"superadmin",deletedAt:null},select:{phone:true,name:true}}));await p.$disconnect()})'
```

### Removing accounts

```bash
npm run backup
node --env-file=.env scripts/prune-accounts.mjs --keep "+993…,+993…"   # dry run
node --env-file=.env scripts/prune-accounts.mjs --keep "+993…,+993…" --confirm-delete
```

Two consequences that are not obvious from the schema. Deleting a store's only
admin **orphans the store** — the store and its posts survive, because they
belong to the Store rather than the user, but no account holds the store-admin
role and only a superadmin can manage it. And an account with orders **cannot
be deleted at all**: `Order.userId/adminId` carry no cascade, so MySQL refuses.
That is deliberate; the product anonymises accounts in place so sales history
survives (`08_OPERATIONS.md` §8).

### Demo account (app-store review)

Reviewers cannot receive an SMS on a Turkmen number, and a reviewer who cannot
log in rejects the build. In `server/.env`:

```ini
OTP_TEST_PHONE="+99363538839"
OTP_TEST_CODE="123456"
```

That number then logs in with the fixed code, sending no SMS and skipping the
resend cooldown. It is a bypass with a permanent, published credential, so it
**refuses unless the account's role is plain `user`** — returning 403 and
logging at error level. Promoting that number would otherwise hand the
published code real privileges with no outward sign. Leave both blank to
disable.

## 5d. Firebase (FCM push)

Firebase is push only (`CLAUDE.md` rule 4). Everything below is project
`semay-b57ee`. The identifiers are not secrets (`08_OPERATIONS.md`, "Checked
and deliberately NOT changed") and are recorded here so nobody has to open the
console to find them.

| | |
|---|---|
| Project ID | `semay-b57ee` |
| Project number / FCM sender ID | `185543007684` |
| Android app | package `com.semay.semay`, app ID `1:185543007684:android:8330f92b64b7072011d891` |
| iOS app | bundle `com.semay.semay`, app ID `1:185543007684:ios:097de46705573a8d11d891` |
| Web app | `1:185543007684:web:025b97f3d38e2f0511d891` — not a shipping target |
| Server sender | `firebase-adminsdk-fbsvc@semay-b57ee.iam.gserviceaccount.com`, FCM HTTP v1 API |

**App side — nothing to install.** The per-platform config lives in
`mobile/lib/core/firebase_options.dart` and `Firebase.initializeApp` reads it
directly, so there is no `google-services.json` or `GoogleService-Info.plist`
in the repo and neither native project references one. If an app is ever
re-registered in the console, regenerate that file (`firebase apps:sdkconfig`)
rather than adding the native files.

**Server side — the one credential.** Console → Project settings → Service
accounts → *Generate new private key*; save the download as
`server/serviceAccount.json` (git-ignored — confirm with
`git check-ignore server/serviceAccount.json` before anything else touches it).
Restart the API and read the boot log:

- `FCM push enabled` with `{"fcm":{"projectId":"semay-b57ee","clientEmail":"firebase-adminsdk-fbsvc@…"}}` — good.
- `FCM push is DISABLED` with a reason — fix the reason. The server checks the
  key's `project_id` against `FIREBASE_PROJECT_ID` at boot and refuses an
  app/web config saved under the same name; either would otherwise load fine
  and fail every send.

The key is read once, at boot — after placing or replacing it, restart the
service (§12); a running process keeps whatever it had. Two more places say
whether push is really on, without reading the boot log:

- Every skipped push logs `push skipped: FCM disabled` with the same reason
  (`08_OPERATIONS.md` §3b) — `grep "push skipped" LOG_DIR/app.*.log` on a
  server that has been sending chat messages or broadcasts.
- The panel's *Broadcast* page: the API answers with `pushEnabled`, and when it
  is false the form shows an amber warning with the reason under "Sent: N".
  "Sent" counts in-app inbox rows, not pushes — with push off, users see the
  broadcast only in the in-app list on their next open, and nothing pops.

If the boot log says enabled and a phone still gets nothing: the device must
have a row in `user_fcm_tokens` (none = the app never registered — Android 13+
notification permission denied, or the token sync failed), and on Android the
app's three channels must be enabled in system settings. **They are labelled in
the DEVICE's language, not the in-app one** — the app ships Turkmen and Russian
only, so the rows read:

| channel | Turkmen (`res/values`) | Russian (`res/values-ru`) |
| --- | --- | --- |
| chat (`chat_messages`) | Habarlar | Сообщения |
| announcements | Bildirişler | Уведомления |
| orders | Sargytlar | Заказы |

All three use the phone's default notification sound. On a handset that ran one
of the intermediate test builds, "1 deleted category" next to them is the
retired `chat_messages_v2` channel, which the app deletes at startup —
expected, see `08_OPERATIONS.md` §3b. If chat is *silent* on such a handset
after updating (rather than ringing with the default), its `chat_messages`
channel was created by an intermediate build that pinned a sound file no longer
shipped: a channel's sound is immutable, so clear the app's data or reinstall.
Only test handsets can be in this state — no released build ever set a sound.

The Admin SDK talks to the FCM HTTP v1 API. The legacy Cloud Messaging API and
its server key are deprecated and disabled in the project — leave them so; the
server never needs a server key.

**iOS — portal work, or no iOS push ever.** Apple Developer → Keys → create an
APNs key and download the `.p8`; upload it in Firebase (Project settings →
Cloud Messaging → Apple app configuration) with its Key ID and your Team ID,
and while there set the Team ID and App Store ID on the iOS app (Project
settings → General → iOS app). The Push Notifications capability must be on
the `com.semay.semay` App ID (`codemagic.yaml` header, step 4). All of this
fails silently: without it the app runs, `getToken()` has nothing to register,
and no push arrives (`08_OPERATIONS.md` §3b).

**Not needed — don't chase these.**

- *Web push VAPID key pair* — web is not a shipping target. If it ever is,
  `notification_service.dart` takes the key as `--dart-define=FCM_VAPID_KEY=…`.
- *Android SHA-1 / SHA-256 fingerprints* — only Phone Auth, App Check and
  Dynamic Links need them, and this app uses none (auth is the custom OTP
  flow). FCM works without them.

## 5e. Share links & deep links

A share from the app is a public https link (`docs/04` "Share links"):
`https://semaycollection.com/p/<postId>`, `/r/<postId>` (reel), `/s/<storeId>`,
answered by the API's own share page — five root-mounted unauthenticated routes
(`server/src/share/routes.ts`; what they expose, and what they deliberately do
not, is `docs/08_OPERATIONS.md` §6f). Their env vars are the `SHARE_*` block in
§4; the only one an operator normally sets is `SHARE_ANDROID_CERT_SHA256`, plus
`SHARE_PLAY_URL` / `SHARE_APPSTORE_URL` **once each of those listings is
actually published** (both ship empty and render a "coming soon" badge — do not
fill one in on the assumption that the listing exists). nginx needs no change —
`location /` already proxies these paths to the API for both hosts.

Check the server half right after a deploy:

```bash
ID=00000000-0000-4000-8000-000000000000
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://semaycollection.com/p/$ID    # 200 text/html; charset=utf-8
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://semaycollection.com/p/$ID/   # 200 text/html  (trailing slash too)
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://semaycollection.com/p/nope   # 404 text/html  (NOT the JSON error)
curl -s https://semaycollection.com/.well-known/assetlinks.json | node -e "let j=JSON.parse(require('fs').readFileSync(0));console.log(j[0].target.package_name, j[0].target.sha256_cert_fingerprints)"
curl -s -o /dev/null -w '%{http_code}\n' https://semaycollection.com/.well-known/apple-app-site-association   # 404 until SHARE_IOS_APP_ID is set, then 200
# Where an Android recipient WITHOUT the app actually lands:
curl -s -A 'Mozilla/5.0 (Linux; Android 14) Chrome/120' https://semaycollection.com/p/$ID | grep -o 'S.browser_fallback_url=[^;]*'
```

An empty `[]` from the `assetlinks` line (the `node` snippet will throw on
`j[0]`) means `SHARE_ANDROID_CERT_SHA256` is unset — App Links can never verify
until it is. The last line must show the URL-encoded `SHARE_PLAY_URL` once that
is configured; while it is empty it shows the share page's own URL, and the
page's Play button reads `Ýakynda` instead of linking.

The app registers two ways in (`mobile/lib/core/share_links.dart`,
`router.dart`, `AndroidManifest.xml`, `Info.plist`):

- `semay://open/p|r|s/<id>` — the custom scheme the share page's "Open in
  SeMay" button uses. Works on a fresh install with no portal or DNS work.
- `https://semaycollection.com/…` (and `www.`) — Android App Links / iOS
  Universal Links, which open the app **directly** from a tapped link, but
  only once each platform has verified the site.

**What works today, before any verification:** a tapped https link opens the
browser page, whose button opens the app through the scheme. The app half
needs nothing else.

**Android App Links — until production serves `assetlinks.json`, a tapped
link opens the browser.** Android fetches
`https://semaycollection.com/.well-known/assetlinks.json` (and the `www.`
one) at install/update and only then routes the link straight into the app.
The site is unreachable at the time of writing, so every current install is
"unverified". After cutover, on a phone with the app installed:

```bash
adb shell pm verify-app-links --re-verify com.semay.semay   # ask Android to fetch again
adb shell pm get-app-links com.semay.semay                   # both hosts must read "verified"
curl -s https://semaycollection.com/.well-known/assetlinks.json | node -e "let j=JSON.parse(require('fs').readFileSync(0));console.log(j[0].target.package_name, j[0].target.sha256_cert_fingerprints)"
```

The fingerprint listed must be the certificate that signs the installed APK —
Play App Signing's *app signing* key for Play installs, the upload/debug key
for side-loaded builds (`keytool -printcert -jarfile app-release.apk` shows
it); a mismatch verifies as "none" with no other symptom.

Drive the app without the site at all — run each once with the app killed
(cold) and once with it open on another screen (warm). **The warm case has a
second thing to check:** open the app, go two screens deep (Search → a store
profile), then fire the link. The linked screen must appear *on top of those
two*, and back must return to the store profile — not to Home. (go_router's own
handling of a platform route replaces the whole stack, which is why
`router.dart` intercepts a warm link before it gets there.)

```bash
adb shell am start -a android.intent.action.VIEW -d "https://semaycollection.com/p/<postId>" com.semay.semay   # post detail over Home; back returns to Home
adb shell am start -a android.intent.action.VIEW -d "semay://open/s/<storeId>"                                   # store profile
adb shell am start -a android.intent.action.VIEW -d "semay://open/r/<postId>"                                    # reel, in the full-screen player
```

Signed out: the link must survive the login screens — log in, and the linked
screen opens on top of Home.

**iOS — the scheme works now; Universal Links are portal work.** The app
declares `semay` in `CFBundleURLTypes` with `FlutterDeepLinkingEnabled`. On a
simulator or device:

```bash
xcrun simctl openurl booted "semay://open/p/<postId>"   # post detail over Home
xcrun simctl openurl booted "semay://open/s/<storeId>"  # store profile
```

Safari → `https://semaycollection.com/p/<postId>` renders the share page and
its button opens the app.

**Expect this on an iPhone that does NOT have the app:** tapping "Open in
SeMay" raises Safari's modal *"Safari cannot open the page because the address
is invalid"*. The button is a bare `semay://` scheme — the only thing that can
open the app before the entitlement below exists — and no JS-free page can tell
in advance whether the scheme is registered. It is not a regression, and the
App Store button underneath is the route that works for that visitor (once
`SHARE_APPSTORE_URL` is set; while it is empty that button reads `Ýakynda`).
Setting up Universal Links, below, is what removes the alert.

For the link itself to open the app (the Universal Link banner / direct open)
the owner has to, in this order:

1. Apple Developer → Identifiers → `com.semay.semay` → enable **Associated
   Domains**, then regenerate the provisioning profiles (Codemagic picks them
   up on the next build).
2. Only then add `com.apple.developer.associated-domains` =
   `applinks:semaycollection.com` (and `applinks:www.semaycollection.com`) to
   `mobile/ios/Runner/Runner.entitlements`. **Not before:** an entitlement the
   App ID lacks fails signing and the archive never builds — which is why it
   is deliberately absent from the repo today.
3. Set **`SHARE_IOS_APP_ID`** in `server/.env` to the same `<TEAM ID>.<bundle
   id>` and restart. Until it is set the route answers **404 on purpose**;
   setting it is what makes it serve the document
   (`curl -sI https://semaycollection.com/.well-known/apple-app-site-association | grep -i content-type`
   → `application/json`). Apple fetches it through its own CDN at install time,
   so the site has to be reachable from the internet, not just from the office.
4. **Then allow for Apple's cache.** The AASA is fetched via
   `app-site-association.cdn-apple.com`, not from this origin directly, and the
   result is cached — which is exactly why an empty document is never
   published. After setting `SHARE_IOS_APP_ID`, delete and re-install the app
   (or use Settings → Developer → Associated Domains Development to force a
   direct fetch) before concluding Universal Links are broken.

The scene-based iOS runner (`SceneDelegate: FlutterSceneDelegate`) has not
been exercised with a URL from this Windows box — `xcrun simctl openurl`
above is the check to run before the first TestFlight build goes out.

## 6. Build & run

```bash
cd server
npm run build         # tsc -> dist/
npm start              # single process, node --env-file=.env dist/index.js
# or, once REDIS_URL is set:
npm run start:cluster  # one worker per core (CLUSTER_WORKERS=0), refuses to
                        # boot if the connection-limit math (§4) doesn't fit
```

### Smoke test against a real boot

```bash
npm run smoke          # boots src/index.ts on port 18080 with the local .env
```

Logs in as the demo account (so `OTP_TEST_PHONE`/`OTP_TEST_CODE` must be set),
checks that `/health/ready` reports the realtime bus live when `REDIS_URL` is
set (`bus.ready:true` — the message round-trip below runs on one process and
would pass with a dead Redis) and that `/health/realtime` answers,
opens a WebSocket, checks ping/pong, subscribes
to the chat list, sends one message to the first store and watches it echo
over the socket, then checks a bad token is closed with 4401. This is the "verify by booting" check from
`CLAUDE.md` rule 9 made repeatable — `inject()`-based tests never exercise the
listener. It writes one message into a real chat, so use it on dev/staging
data only.

## 7. Running as a Windows service

This is how the API stays up across reboots on the current box — the
alternative (a bare `npm start` in a terminal someone remembers to reopen) is
exactly the failure mode this closes. Defined in code
(`server/scripts/service.mjs`), not clicked together by hand, so it's
reproducible on a fresh machine.

```bash
cd server
npm run build             # service runs dist/ — build first, every time
npm run service:install   # elevated shell required
```

This registers **"SeMay API"** (process name `semayapi.exe`), auto-start,
restart-on-crash with backoff (capped at 10 restarts so a genuinely broken
build fails visibly instead of spinning forever), and passes
`--env-file=.env` explicitly so it can't boot unconfigured.

```bash
npm run service:uninstall   # remove it (elevated shell)
```

**The service does not hot-reload.** After any code or `.env` change:

```bat
npm run build
net stop "semayapi.exe" && net start "semayapi.exe"
```
(Administrator shell for `net stop`/`net start`.)

## 8. Firewall & network exposure

By default Fastify binds `0.0.0.0:$PORT` (`server/src/index.ts`) — reachable
from anywhere that can route to the box, not just `localhost`. For LAN-only
testing (e.g. a phone on the same Wi-Fi instead of `adb reverse`), open the
port in Windows Defender Firewall:

```powershell
New-NetFirewallRule -DisplayName "SeMay API" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

**Do not forward that port straight to the public internet.** There's no TLS
on the bare Node process — put a reverse proxy in front first (§9) and only
expose *its* port (443) externally. If this box sits behind a home/office
router, that also means no port-forwarding rule for 8080 itself, only for
whatever the reverse proxy listens on.

## 9. Reverse proxy / TLS

**Not yet configured on this box** — the API currently listens directly on
`0.0.0.0:$PORT` with no TLS termination in front of it. Recommended production
topology (`08_OPERATIONS.md` §1), for when this is set up:

```
Caddy / Nginx (TLS, :443)
  ├─ /api/* and /ws  → semay-server process(es) on PORT
  └─ /media/*        → file_server rooted at MEDIA_DIR  (bypasses Node entirely)
```

Serving `/media/*` as static files from the reverse proxy instead of through
Node matters once traffic grows — media is the highest-bandwidth path in the
app, and a static file server does it at near-zero CPU while Node would be
competing with API requests for the event loop.

## 10. Health checks & triage

```bash
curl http://localhost:8080/health          # liveness — always cheap, no DB query
curl http://localhost:8080/health/ready    # readiness — probes the DB, reports the realtime bus; rate-limited, ~2s cache
curl http://localhost:8080/health/realtime # realtime readiness — fails closed where the bus is required
```

`/health/ready` answers `{ ok, db, degraded, realtime, bus: { mode, ready,
droppedPublishes } }` — `bus` is the realtime pub-sub (`08_OPERATIONS.md` §3d).
It is the **HTTP** load balancer's health check and its status code follows the
**database** only: a Redis outage shows up as `degraded:true` /
`realtime:false` and a 200, because everything but realtime fan-out still
works.

`/health/realtime` answers `{ ok, required, degraded, bus }` and is the one
that **fails closed** — 503 once the bus has been gone past the grace period
where Redis is required (a cluster worker, or `REDIS_REQUIRED=true`). Point the
**WebSocket** upstream's health check and your alerting at this one.

Neither endpoint takes authentication, so the Redis host:port and the raw
ioredis error text are deliberately kept off both; they are in the log line the
triage step below points at.

If the mobile app or web-admin can't reach the API:

1. `curl localhost:8080/health` fails → the API service itself is down. Check
   `net start` output / Windows Event Viewer, or run `npm run build && node dist/index.js`
   directly to see the boot error.
2. `/health` succeeds but a **physical device** still errors → almost always
   the `adb reverse tcp:8080 tcp:8080` tunnel, which has to be re-run every
   time the phone reconnects over USB (`mobile/README.md`) — or, for a device
   on the same Wi-Fi rather than USB, the firewall rule in §8.
3. `/health` succeeds but `/health/ready` fails with `db:false` → MySQL is
   unreachable or out of connections (`Max_used_connections` in
   `SHOW GLOBAL STATUS`).

If chat messages stop arriving live (sent ones appear, incoming ones only
after reopening the thread):

4. `/health/ready` is 200 but `degraded:true` / `bus.ready:false` →
   `REDIS_URL` is set and Redis is not answering. **For the host and the
   reason, grep the log, not the endpoint** — the readiness body carries no
   error text on purpose (it is unauthenticated):

   ```powershell
   # LOG_DIR is from server/.env and defaults to server/logs
   Select-String -Path "LOG_DIR\app.*.log" -Pattern "realtime: Redis"
   ```

   The `realtime: Redis error` lines carry `redis:` (the host:port) and `err:`
   (the reason); `realtime: Redis connection lost` is when it went, and
   `realtime: Redis reconnected` (with `downMs` and `droppedPublishes`) is when
   it came back. Chat still works for sockets on this process, and NOT across
   workers or machines — `bus.droppedPublishes` counts the events that stayed
   in-process. Start the Redis service (and make it auto-start), or empty
   `REDIS_URL` if this really is a single process.
5. `/health/realtime` is 503 while `/health/ready` is still 200 → the bus has
   been down for over 30 s on a cluster worker (or with `REDIS_REQUIRED=true`).
   Same fix as 4. The split is deliberate: the REST API keeps serving (nothing
   but realtime fan-out needs Redis, and every box sharing one Redis would
   otherwise go out of rotation at the same instant, taking the whole site
   down), while the WebSocket upstream stops routing here. That process
   **also closes the WebSockets it is already holding** (close code 4503, one
   `realtime: the bus this process needs has been down past the grace period`
   line per sweep) and answers new subscribes `SUBSCRIBE_FAILED` — so expect a
   burst of reconnects and phones showing "Connecting…" while it is in this
   state; that is the design, not a second fault (`08_OPERATIONS.md` §3d).
   `start:cluster` itself refuses to boot when Redis is unreachable at start —
   the console names the host.

## 11. Backups

```bash
cd server
npm run backup           # dump, gzip, prune to the last 14 (BACKUP_KEEP)
npm run backup:verify    # dump, then restore into a scratch schema and
                          # compare every table's row count + FK/index totals
```

- Output goes to `BACKUP_DIR` (default `C:/Users/User/Desktop/semay-backups`).
- Connection details are read from `DATABASE_URL`, so backups follow the app
  if it's ever repointed — nothing hardcoded to drift out of sync.
- **Schedule it** — Windows Task Scheduler, daily, running
  `node --env-file=.env scripts/backup.mjs` from `server/`. Exit code is 1 on
  failure, so a scheduled task can alert on it.
- **Keep at least one copy off this machine.** A backup on the same disk as
  the database is not a backup.

Restore:

```bash
node --env-file=.env scripts/backup.mjs --restore <file.sql.gz> --into <db-name>
# refuses to overwrite the live database unless you pass --yes-overwrite-live
```

## 12. Redeploying a code change

The day-to-day loop once the service is already installed:

```bash
cd server
git pull
npm install                    # only if dependencies changed
npm run build                  # the running service keeps serving the OLD build meanwhile
net stop "semayapi.exe"                                # Administrator shell
npm run prisma:deploy          # only if there are new migrations — with the service STOPPED
net start "semayapi.exe"
curl http://localhost:8080/health/ready                # confirm it came back
```

Build first, then stop, migrate, start: the old build must never serve on the
new schema. It does not know the new columns, so a `NOT NULL` column without a
database default (`sessions.familyId`, added by `sessions_until_logout`) gets
no value from it — `''` on a non-strict MySQL, which would have merged every
login made in that window into one cross-user family (`08_OPERATIONS.md` §3c
has the guard that now contains it), or a failed INSERT on a strict one, i.e.
every login and refresh 500s until the restart. Building before the stop
keeps the gap to the few seconds the migration and the restart take.

If `schema.prisma` changed, `web-admin` needs its mirrored copy refreshed too
— its own `npm run dev` / `npm run build` calls `sync-schema.mjs`
automatically first; never hand-edit `web-admin/prisma/schema.prisma`
directly (`CLAUDE.md`).

## 13. web-admin (Super Admin panel)

Separate Next.js app, same database, same JWT secret:

```bash
cd web-admin
cp .env.local.example .env.local
# DATABASE_URL: same MySQL database server/ uses
# JWT_SECRET: must exactly match server/.env's value
# API_BASE_URL: http://localhost:8080/api/v1 (or wherever server/ is reachable)
# MEDIA_DIR: must resolve to the SAME folder as server/'s MEDIA_DIR
# MEDIA_PUBLIC_BASE_URL: must match server/.env's value
npm install
npm run build     # runs sync-schema.mjs first, then next build
npm start
```

The panel's session follows the API's rules (`08_OPERATIONS.md` §3c): it lasts
until the Logout button, refreshed silently by `src/proxy.ts` behind a 400-day
`refresh_token` cookie. If the API is down when the access token expires, the
protected pages show a "Reconnecting…" 503 that retries itself — that is not a
logout, and nothing needs re-entering once the API is back.

## 14. Before this serves real users

Carried over from `08_OPERATIONS.md` §7b — check these off before real launch,
not just real testing:

- [ ] Restart MySQL **and** the API after any MySQL tuning or code fix — a
      running service holds the old build in memory; `dist/` alone updating is
      not enough.
- [ ] Real `serviceAccount.json` in place for FCM (§5d) — the boot log must say
      `FCM push enabled` for project `semay-b57ee`; `FCM push is DISABLED`
      means push is silently off, and the reason next to it says why. Then
      prove it end to end: send a broadcast from the panel — no amber
      "push disabled" warning, `broadcast push done` in the log with
      `sent > 0`, and a phone with the app OPEN on the feed shows a heads-up
      notification with the system default sound on the announcements channel
      (**Bildirişler** / ru **Уведомления** — Android labels channels in the
      DEVICE's language; tap opens the inbox); a chat message sent to that
      phone while it is on another screen — chat list, inbox, another thread,
      backgrounded, killed — rings with the phone's default notification sound
      on the chat channel (**Habarlar** / **Сообщения**) and opens the thread;
      the thread that is on screen stays quiet (badge only on iOS) and its
      pending notification disappears from the shade / Notification Center as
      it opens; a "New order" to a superadmin uses the default sound on the
      orders channel (**Sargytlar** / **Заказы**) (`08_OPERATIONS.md` §3b).
      **Deploy the server before or with the app release**: only the server
      names the `orders` channel, so a new app taking an order push from an old
      server falls through to the manifest default, which is the chat channel
      (same sound, wrong category). iOS additionally: a foreground push on any
      screen but the thread it belongs to shows a banner with the default
      sound.
- [ ] **No custom notification sound ships.** The bundled chat sound was
      removed at the owner's request; all three channels take the phone's
      default. After `flutter build apk --release`, neither the sound asset nor
      any reference to it may be left in the APK:

      ```bash
      cd mobile
      python -c "import zipfile;z=zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk');print([n for n in z.namelist() if 'semay_message' in n or (n.startswith('res/') and z.read(n)[:3]==b'ID3')])"
      # -> []   (any entry means an asset came back)

      python -c "import zipfile;z=zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk');print([n for n in z.namelist() if n.endswith('.dex') and b'semay_message' in z.read(n)])"
      # -> []   (a hit means Dart or Kotlin still names the resource)
      ```

      If a custom sound is ever brought back, read the release-build shrinker
      trap in `08_OPERATIONS.md` §3b FIRST — a name-only reference is invisible
      to AGP's shrinker, which stripped the asset once and left background chat
      pushes silent, and a channel's sound cannot be changed after creation.
- [ ] iOS push chain (§5d): APNs auth key uploaded to the Firebase project
      (Project settings → Cloud Messaging → Apple app configuration) and the
      Push Notifications capability enabled on the `com.semay.semay` App ID. The
      entitlement and background mode are in the repo; without the portal side
      no iOS device ever gets an APNs token, and the app runs fine otherwise —
      so this fails silently (see `docs/08_OPERATIONS.md` §3b).
- [ ] Chat liveness on a real device (see `docs/08_OPERATIONS.md` §3a): lock
      the phone for 5+ minutes, send from the other side, unlock — the message
      must be there within a few seconds (the resume probe waits up to 5 s for a
      pong before it reconnects; "Connecting…" may flash under the title);
      toggle airplane mode on/off with the thread open; leave the app open 20+
      minutes (past the access-token TTL) and confirm messages still arrive;
      tap a push with the app killed and confirm it opens that thread.
- [ ] Read receipts and unread, with the account on ONE phone at a time. The
      same account signed in on a second device is a legitimate reader: when
      that device opens a thread it posts the read receipt — the sender sees
      two blue ticks and "Seen HH:MM", this phone's badge for the chat clears,
      and a message can show as read before this phone was touched. That is
      correct behaviour, not a receipts bug (the owner has two phones — sign
      the other one out, or leave its thread closed, before judging receipt
      timing on this one). What to check, store phone on the thread and
      customer phone on Home: a store message shows one grey tick, then two
      grey within a second (the customer's chat list stamped it delivered);
      the customer's Chat tab badge and the row's pill show the count; two
      blue ticks plus "Seen HH:MM" under the newest message appear only when
      the customer opens the thread, and the badge clears then. Then the same
      with the roles swapped. A stalled socket shows "Connecting…" under the
      title and the ticks catch up on the reconnect.
- [ ] Chat cache / scroll-back / media (docs/07 Phase 9d): open a thread,
      kill the app, turn on airplane mode, reopen — the list and the thread's
      recent messages must be there with "Connecting…" under the title; in a
      thread with 200+ messages scroll to the top and confirm older pages load
      without the view jumping; as a store admin send a gallery photo — it
      must appear at once with a progress ring, then double-tick; a photo sent
      in airplane mode must go out by itself when signal returns.
- [ ] **Gate — `REFRESH_TOKEN_TTL_DAYS` in the deployed `server/.env` is 730
      or absent.** The file value wins over the code default, and the value
      every `.env` written before 2026-09 carries (30) silently reinstates the
      monthly logout the whole session change exists to remove. Check with
      `findstr REFRESH_TOKEN_TTL_DAYS .env` on the server before starting the
      new build, and again by reading `expiresAt` on a fresh login's
      `sessions` row (≈ two years out, not one month).
- [ ] Sessions until logout (`08_OPERATIONS.md` §3c): on a phone, use the app
      past the access-token TTL, toggle airplane mode during a refresh, and
      force-kill/relaunch — no login screen until Sign out, and Sign out must
      revoke the server rows. (A kill that lands mid-refresh, after the server
      rotated but before the phone stored the new pair, survives only a
      relaunch inside the 60 s grace; later than that the phone is logged out
      once, by design — the replayed token is a replay.) In the panel, open
      three tabs, wait 15+ minutes, reload all three — all stay signed in and
      the API log shows one `/auth/refresh` per burst; stop the API and reload
      — "Reconnecting…", not `/login`; Logout, then a stale tab's next
      navigation lands on `/login`.
- [ ] Chat delete hides history (docs/07 Phase 5, `hideChat`): the API can go
      first, but the app build carrying `ChatMessagesNotifier`'s cutoff/cache
      handling must be in the stores before the "deleted history never comes
      back" promise is made to users — an older build still paints its own
      cached rows around the next reply until it updates. On a phone: delete a
      thread with 200+ messages, have the store reply quoting an old message,
      reopen — only the reply, without the quote excerpt, and no older page.
- [ ] On-device matrix tested, including the offline-outbox replay loop
      (airplane mode → send → restore signal → exactly one message lands).
- [ ] `JWT_SECRET` rotated away from the development value, **and** the
      superadmin password changed via `POST /auth/superadmin/change-password`
      (never by reading/writing `passwordHash` directly).
- [ ] Backup scheduled as a recurring task, with a copy stored off this
      machine.
- [ ] SMS gateway configured for the right mode (§5b) — Cloud relay for a
      remote API — with `OTP_DEV_MODE=false`, and a real OTP received on a
      real handset to prove it end to end.
- [ ] Reverse proxy + TLS in front of the API (§9), firewall only exposing
      *that* port to the internet (§8).
- [ ] Share links (§5e): share a post from a phone — the sheet shows a title
      and the message carries `https://semaycollection.com/p/<id>` (never a
      `semay://` string); tapped on a phone WITHOUT the app it opens the share
      page — on Android "Open in SeMay" lands on Google Play once
      `SHARE_PLAY_URL` is set (check `S.browser_fallback_url` per §5e), on
      iPhone it raises Safari's "address is invalid" alert by design and the
      App Store button below is the working route; either store button reads
      "coming soon" while its URL is empty, which is how both ship. On a
      phone WITH the app the post opens over Home (through the page's button
      until App Links verify), and back returns to Home; a warm link fired
      while two screens deep leaves those two screens underneath; the same for
      a reel (`/r/`) and a store (`/s/`), cold, warm and signed out.
      **A mangled link must cost nothing:** forward `…/p/<id>/extra`,
      `…/p/abc123` or a link with trailing punctuation to a phone with the app
      — it must be a no-op over whatever was on screen (warm) or land on Home
      (cold), never go_router's empty "Page Not Found".
      Every share button must also report back: a completed share shows
      "Paýlaşyldy", a dismissed sheet shows nothing, and a sheet that cannot
      open (iPad with no anchor) shows the failure string — from the store
      icon as well as the post/reel one.
      `adb shell pm get-app-links com.semay.semay` reads "verified" for both
      hosts once production serves `assetlinks.json`; iOS Universal Links need
      the portal steps in §5e before the entitlement is added.
