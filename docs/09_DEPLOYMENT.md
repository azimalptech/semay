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
- **`SMS_GATEWAY_URL` / `_USER` / `_PASSWORD`** — required unless
  `OTP_DEV_MODE=true`. Points at a capcom6/sms-gate.app gateway. **Which URL to
  use depends on where the API runs** — see §5b; a remote API must use the Cloud
  relay, not the phone's LAN address.
- **`OTP_DEV_MODE`** — `true` echoes the OTP code in the `/auth/otp/send`
  response instead of sending a real SMS. Convenient for local dev; must be
  `false` before anyone but you can reach the server.
- **`MEDIA_DIR` / `MEDIA_PUBLIC_BASE_URL`** — local disk, not object storage.
  Must resolve consistently if you front it with a reverse proxy (§9).
- **`REDIS_URL` / `CLUSTER_WORKERS`** — leave `REDIS_URL` empty for one process.
  The moment you run `start:cluster` or more than one machine, `REDIS_URL` is
  required — without it, realtime messages published on one worker never reach
  sockets owned by another, and nothing errors to tell you.

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
opens a WebSocket, checks ping/pong, subscribes to the chat list, sends one
message to the first store and watches it echo over the socket, then checks a
bad token is closed with 4401. This is the "verify by booting" check from
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
curl http://localhost:8080/health         # liveness — always cheap, no DB query
curl http://localhost:8080/health/ready   # readiness — probes the DB, rate-limited, ~2s cache
```

If the mobile app or web-admin can't reach the API:

1. `curl localhost:8080/health` fails → the API service itself is down. Check
   `net start` output / Windows Event Viewer, or run `npm run build && node dist/index.js`
   directly to see the boot error.
2. `/health` succeeds but a **physical device** still errors → almost always
   the `adb reverse tcp:8080 tcp:8080` tunnel, which has to be re-run every
   time the phone reconnects over USB (`mobile/README.md`) — or, for a device
   on the same Wi-Fi rather than USB, the firewall rule in §8.
3. `/health` succeeds but `/health/ready` fails → MySQL is unreachable or out
   of connections (`Max_used_connections` in `SHOW GLOBAL STATUS`).

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
npm run prisma:deploy          # only if there are new migrations
npm run build
net stop "semayapi.exe" && net start "semayapi.exe"   # Administrator shell
curl http://localhost:8080/health/ready                # confirm it came back
```

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

## 14. Before this serves real users

Carried over from `08_OPERATIONS.md` §7b — check these off before real launch,
not just real testing:

- [ ] Restart MySQL **and** the API after any MySQL tuning or code fix — a
      running service holds the old build in memory; `dist/` alone updating is
      not enough.
- [ ] Real `serviceAccount.json` in place for FCM (push is silently disabled
      without it — check the boot log for `FCM push is DISABLED`).
- [ ] iOS push chain: APNs auth key uploaded to the Firebase project (Project
      settings → Cloud Messaging → Apple app configuration) and the Push
      Notifications capability enabled on the `com.semay.semay` App ID. The
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
- [ ] Chat cache / scroll-back / media (docs/07 Phase 9d): open a thread,
      kill the app, turn on airplane mode, reopen — the list and the thread's
      recent messages must be there with "Connecting…" under the title; in a
      thread with 200+ messages scroll to the top and confirm older pages load
      without the view jumping; as a store admin send a gallery photo — it
      must appear at once with a progress ring, then double-tick; a photo sent
      in airplane mode must go out by itself when signal returns.
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
