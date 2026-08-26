# 06 — Deployment

> **SUPERSEDED by `09_DEPLOYMENT.md`. Do not follow the steps below.**
>
> Kept for history only. It is stale in at least two ways that will actively
> mislead: it describes **MinIO** for media (replaced by local disk under
> `server/media/`), and the **sms-gate.app** cloud relay for OTP (replaced by
> our own relay in `sms-gateway/`, because that host is unreachable from
> Turkmen networks). Assume anything here is out of date unless `09` agrees.

SeMay no longer runs on Firebase. Since the migration (see `docs/07_MIGRATION.md`) the whole backend
is **self-hosted**, meant to run on a single server physically located in Turkmenistan for data
sovereignty. This doc is how to stand that box up and how to ship updates to it.

## What ships where

| Component | What it is | How it deploys |
|-----------|-----------|----------------|
| `server/` | Node.js/TS + Fastify (REST **and** WebSocket on one port) → Prisma → **MySQL 8**; issues presigned uploads to **MinIO**; sends push via the **Firebase Admin SDK** | Long-running Node process on the box, behind a TLS reverse proxy |
| `web-admin/` | Next.js Super Admin panel — reads MySQL **directly** via Prisma (Server Components + Route Handlers) and calls `server/` for mutations with side effects | Long-running `next start` process on the box (or the same box), behind the same proxy |
| `mobile/` | Flutter app | Built as a signed **release APK/AAB** and installed / shipped to the store — **not** deployed to the server |

**The only remaining Firebase dependency is FCM** (push notifications), reached from `server/` with a
service-account JSON. Everything else — auth, data, media, realtime — is ours.

There is no `firebase deploy` anymore, no Cloud Functions, no Firestore, no Firebase Hosting. The old
`*.run.app` / `__session`-cookie caveats are gone: self-hosting the panel removes them entirely.

---

## Server box — prerequisites

Provision once (this is Phase 0 in the migration plan):

- **Node.js ≥ 20.6** (`server/` is ESM, `type: module`; started with `node --env-file`, which needs
  ≥ 20.6 — 20.12+ recommended for the stable flag).
- **MySQL 8**, a `semay` database + user.
- **MinIO** (S3-compatible) for media, with an access key/secret. The bucket itself is **auto-created**
  on server boot (`ensureMediaBucket` in `server/src/media/minio.ts` calls `makeBucket` + sets a
  public-read policy), so no manual bucket step.
- **A TLS reverse proxy** (Caddy or Nginx) terminating HTTPS for the API, the media host, and the
  panel. This is non-negotiable: the mobile release build only permits cleartext to `localhost` (see
  the mobile section), so the public API **must** be HTTPS.
- **A process manager** — `systemd` units (shown below) or PM2 — to keep `server/` and `web-admin/`
  running and restart them on crash/boot.
- **The FCM service-account JSON** on the box (path referenced by `GOOGLE_APPLICATION_CREDENTIALS`).
  This is the one file to carry over from the Firebase project (Project Settings → Service accounts →
  Generate new private key). Keep it out of git.

---

## Environment configuration

Copy the examples and fill them in. **Never commit the real env files or the service-account JSON.**

### `server/.env` (from `server/.env.example`)

Key values that change for production:

```bash
# At scale, size the Prisma pool: ...:3306/semay?connection_limit=20&pool_timeout=20
DATABASE_URL="mysql://semay:<strong-pw>@localhost:3306/semay"
PORT=8080
WEB_ADMIN_ORIGIN="https://admin.<domain>"        # CORS allowlist for the panel
RATE_LIMIT_MAX_PER_MIN=3000                        # per-IP backstop (generous — carrier NAT)

# Generate: node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
JWT_SECRET="<long-random>"                         # MUST match web-admin's JWT_SECRET
ACCESS_TOKEN_TTL_SECONDS=900
REFRESH_TOKEN_TTL_DAYS=30

# Real SMS gateway (capcom6 / sms-gate.app) — and turn dev mode OFF. URL is the
# base exposing POST /message with Basic auth (phone LAN address, self-hosted
# relay, or the cloud relay https://api.sms-gate.app/3rdparty/v1). REQUIRED when
# OTP_DEV_MODE=false — the server refuses to boot without all three (fail-fast,
# so login can't silently break in prod).
SMS_GATEWAY_URL="..."; SMS_GATEWAY_USER="..."; SMS_GATEWAY_PASSWORD="..."
OTP_DEV_MODE=false                                 # ← critical: true echoes the OTP in the API response

# FCM (push only)
GOOGLE_APPLICATION_CREDENTIALS="/etc/semay/serviceAccount.json"
FIREBASE_PROJECT_ID="<firebase-project-id>"

# Media — MEDIA_ENDPOINT is the server's INTERNAL path to MinIO (bucket create +
# policy). MEDIA_PUBLIC_BASE_URL is the app/browser-reachable HTTPS host, and its
# origin is ALSO what presigned UPLOAD URLs are generated against (a phone must
# be able to PUT to them), so it must include the bucket, e.g.
# https://media.<domain>/semay. Getting these backwards breaks uploads.
MEDIA_ENDPOINT="http://localhost:9000"             # internal, server→MinIO admin
MEDIA_PUBLIC_BASE_URL="https://media.<domain>/semay"  # external: reads AND presign host
MEDIA_BUCKET="semay"
MEDIA_ACCESS_KEY="..."; MEDIA_SECRET_KEY="..."
```

> **`OTP_DEV_MODE` must be `false` in production.** When true, `POST /auth/otp/send` returns the code
> in its response body (and the web-admin login shows it) instead of sending a real SMS — that's a dev
> convenience only.

### `web-admin/.env.local` (from `web-admin/.env.local.example`)

```bash
DATABASE_URL="mysql://semay:<strong-pw>@localhost:3306/semay"   # same DB as server/
JWT_SECRET="<long-random>"                                       # EXACT same value as server/.env
API_BASE_URL="https://api.<domain>/api/v1"                       # server/'s public URL
MEDIA_ENDPOINT="http://localhost:9000"
MEDIA_PUBLIC_BASE_URL="https://media.<domain>"
MEDIA_BUCKET="semay"
MEDIA_ACCESS_KEY="..."; MEDIA_SECRET_KEY="..."
```

The panel verifies the same access tokens `server/` issues (shared `JWT_SECRET`) — it never mints its
own, so the secret **must** match exactly or every login silently fails.

---

## Database — migrate & seed

Prisma migrations are the source of truth for the schema (`server/prisma/migrations/`). On the box:

```bash
cd server
npm ci
npm run prisma:generate       # generate the client
npm run prisma:deploy         # = prisma migrate deploy — applies pending migrations, non-interactive
```

`prisma migrate deploy` is the production-safe command (it never prompts, never resets). **Do not** run
`prisma migrate dev` on the server — that's a dev-only command that can reset data.

Seed the first superadmin (there's no self-service bootstrap). The seed lives in **`web-admin/`**
(`web-admin/scripts/seed.ts`), which upserts a `role: 'superadmin'` user:

```bash
cd web-admin
npm run seed                  # sync-schema + tsx --env-file=.env.local scripts/seed.ts
```

Edit `web-admin/scripts/seed.ts` first to set the intended superadmin phone (it defaults to
`+99361000001`). After seeding, that phone logs into the panel via OTP — no password.

---

## Build & run `server/`

```bash
cd server
npm ci
npm run prisma:generate
npm run build                 # tsc -> dist/
npm start                     # node --env-file=.env dist/index.js  (listens 0.0.0.0:PORT)
```

Run it under `systemd` so it survives reboots/crashes:

```ini
# /etc/systemd/system/semay-api.service
[Unit]
Description=SeMay API (Fastify + WS)
After=network.target mysql.service

[Service]
WorkingDirectory=/opt/semay/server
ExecStart=/usr/bin/node --env-file=.env dist/index.js
Restart=always
RestartSec=3
User=semay
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now semay-api
```

The server exposes `GET /health` (`{"ok":true,...}`) for liveness checks and proxy health probes.

---

## Build & run `web-admin/`

```bash
cd web-admin
npm ci
npm run build                 # runs sync-schema (copies server/prisma/schema.prisma) then next build
npm start                     # next start -> serves on :3000
```

`sync-schema` keeps the panel's Prisma schema identical to `server/`'s single source of truth — never
edit `web-admin/prisma/schema.prisma` by hand. A matching `systemd` unit (`semay-admin.service`,
`ExecStart=/usr/bin/npm start`, `WorkingDirectory=/opt/semay/web-admin`) keeps it alive.

---

## Reverse proxy / TLS (Caddy example)

Three public hostnames, all HTTPS. Caddy auto-provisions certificates:

```caddy
# API — REST + WebSocket share one upstream port; Caddy proxies ws upgrades transparently.
api.<domain> {
    reverse_proxy localhost:8080
}

# Media — public object reads AND presigned uploads (the app PUTs directly to
# https://media.<domain>/...). Caddy preserves the Host header by default, which
# MinIO needs to validate the presigned-upload signature (it's computed against
# this same host). Videos are up to ~100 MB; reverse_proxy streams, no limit.
media.<domain> {
    reverse_proxy localhost:9000
}

# Super Admin panel.
admin.<domain> {
    reverse_proxy localhost:3000
}
```

`https://api.<domain>` automatically gives the app `wss://api.<domain>/api/v1/ws` — the mobile client
derives the WS URL by swapping `http`→`ws` on `API_BASE_URL`, so HTTPS in means WSS out, no extra
config.

---

## Mobile release build

The app is **not** deployed to the server — it's built and distributed as an artifact. Point it at the
public API with a `--dart-define` (default is `http://localhost:8080/api/v1` for tethered dev):

```bash
cd mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=https://api.<domain>/api/v1
# or, for the Play Store:
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://api.<domain>/api/v1
```

Notes:

- **HTTPS is mandatory in production.** `android/app/src/main/res/xml/network_security_config.xml`
  permits cleartext only for `localhost`/`127.0.0.1` (the `adb reverse` dev tunnel). A real HTTP host
  will be blocked — the public API must be HTTPS (→ WSS), which is why the proxy above is required.
- **Signing.** The release build currently signs with the **debug** keystore
  (`android/app/build.gradle.kts` → `signingConfig = signingConfigs.getByName("debug")`) so
  `flutter build --release` works out of the box. Before a Play Store upload, add a real upload keystore
  and point the `release` build type at it.
- R8 minification is on for release; `android/app/proguard-rules.pro` keeps it happy about uCrop's
  unused OkHttp code path. Leave it in place.
- Bump `version:` in `mobile/pubspec.yaml` (`x.y.z+build`) for each store submission.

### Tethered testing against a local server (no deploy)

For QA on a USB-connected device against a dev server, no HTTPS/proxy needed — the loopback cleartext
rule covers it:

```bash
adb reverse tcp:8080 tcp:8080          # phone's localhost:8080 -> this machine's server
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## Backups & ops (the standing cost of self-hosting)

Firebase did this for free; now the team owns it. Before any real launch:

- **MySQL**: nightly `mysqldump` **and** binlog retention for point-in-time recovery. **Do a
  restore drill** — an untested backup isn't a backup.
- **MinIO**: back up the object data directory (or mirror the bucket to a second location). Media URLs
  in the DB are useless without the bytes behind them.
- **The FCM `serviceAccount.json`** and the env files: store securely and separately (a leak of
  `JWT_SECRET` forges sessions; a leak of the DB password or MinIO keys is total compromise).
- **Monitoring**: alert on `GET /health` failing, on the systemd units flapping, and on disk usage
  (MySQL + MinIO both grow). Watch the API logs for 5xx spikes.
- **OS/TLS**: keep the box patched; Caddy renews certs automatically, Nginx needs a certbot timer.

---

## Shipping an update

Backend (API and/or panel):

```bash
# on the box
cd /opt/semay && git pull
cd server && npm ci && npm run prisma:generate && npm run prisma:deploy && npm run build
sudo systemctl restart semay-api
cd ../web-admin && npm ci && npm run build
sudo systemctl restart semay-admin
```

`prisma migrate deploy` only applies **new** migrations and is safe to run every deploy (a no-op when
there's nothing pending). Restarts are quick; the proxy briefly 502s during the API restart, then
recovers — schedule schema-changing deploys for a low-traffic window.

Mobile: rebuild the release artifact (above) with the same `API_BASE_URL`, bump the version, and push
to the store / redistribute the APK.

## Pre-flight checklist

- [ ] `server/` typechecks (`npm run typecheck`) and tests pass (`npm test`).
- [ ] `web-admin/` typechecks (`npx tsc --noEmit`) and builds (`npm run build`).
- [ ] All migrations applied (`npm run prisma:deploy` clean).
- [ ] `OTP_DEV_MODE=false`, `JWT_SECRET` identical in both env files, real SMS gateway configured.
- [ ] `serviceAccount.json` present and `GOOGLE_APPLICATION_CREDENTIALS` points at it.
- [ ] HTTPS live for `api.` / `media.` / `admin.`; `GET https://api.<domain>/health` returns `ok`.
- [ ] Superadmin seeded; OTP login into the panel works.
- [ ] Mobile release built with the production `API_BASE_URL`; smoke-tested (feed loads, WS connects,
      login, an order, a push).
- [ ] Backups scheduled and a restore verified.
