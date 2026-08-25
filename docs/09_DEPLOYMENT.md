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

OTP codes are sent through a phone running the
[capcom6 / sms-gate.app](https://sms-gate.app) Android app. The server-side
integration is already implemented (`server/src/auth/sms.ts`) — bringing it up
is purely configuration.

**Choose the mode by where the API runs.** This is a reachability constraint:

| API location | Mode | Why |
|---|---|---|
| Same LAN as the phone | **Local Server** — `http://<phone-ip>:8090` | Lowest latency, and the OTP text never leaves your network. |
| Hosted / remote box | **Cloud relay** — `https://api.sms-gate.app/3rdparty/v1` | The phone's LAN IP is a private address behind NAT; a remote server cannot route to it. The phone holds an *outbound* connection to the relay instead, so nothing inbound is needed. |

The current production deployment is remote, so it must use the **Cloud relay**.

In the gateway app, enable the **Cloud server** toggle and read the credentials
off its "Cloud server" card — they are **separate from** the Local Server
username/password. Then, in `server/.env`:

```ini
SMS_GATEWAY_URL="https://api.sms-gate.app/3rdparty/v1"
SMS_GATEWAY_USER="<cloud username>"
SMS_GATEWAY_PASSWORD="<cloud password>"
OTP_DEV_MODE=false
```

`OTP_DEV_MODE=false` is what actually switches `sms.ts` from the dev logger to
the real gateway. The server **refuses to boot** if it's false while any of the
three gateway values are blank (`config.ts`), so a half-configured gateway
fails loudly at startup instead of silently 502-ing every login.

On the phone, keep **Start on boot** enabled and exclude the app from battery
optimisation — a killed gateway means no OTP, and the only symptom users see
is that login stops working.

Verify after deploying (§12) with a real login attempt, or directly:

```bash
curl -u "<cloud user>:<cloud password>" \
  -H "Content-Type: application/json" \
  -d '{"phoneNumbers":["+993XXXXXXXX"],"message":"SeMay test"}' \
  https://api.sms-gate.app/3rdparty/v1/message
```

> Do not commit real gateway credentials. `server/.env` is gitignored; keep them
> there and nowhere else in the repo.

## 6. Build & run

```bash
cd server
npm run build         # tsc -> dist/
npm start              # single process, node --env-file=.env dist/index.js
# or, once REDIS_URL is set:
npm run start:cluster  # one worker per core (CLUSTER_WORKERS=0), refuses to
                        # boot if the connection-limit math (§4) doesn't fit
```

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
