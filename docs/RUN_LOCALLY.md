# Running SeMay locally (this machine)

Everything runs natively on Windows (no Docker). Five moving parts, start them in
this order. Commands assume the repo at `c:\Users\emin1\semay` and Git Bash /
PowerShell.

```
MySQL ──┐
MinIO ──┼──►  server/ (:8080)  ──►  web-admin/ (:3000)
        │                     └──►  mobile app (USB tunnel)
OTP phone (SMS gateway) ──────────► real OTP SMS
```

---

## 0. One-time prerequisites (already installed here)

- **MySQL 8** — runs as a Windows service (`mysqld`), database `semay`, user `semay`.
- **MinIO** — installed via WinGet at
  `…\WinGet\Packages\MinIO.Server_…\minio.exe`.
- **Node ≥ 20.6**, **Flutter**, **Android platform-tools** (`adb`).
- `server/.env` and `web-admin/.env.local` — already filled in.

If starting on a fresh machine, also run once in `server/`:
`npm ci && npm run prisma:generate && npm run prisma:deploy` and seed a
superadmin from `web-admin/`: `npm run seed` (phone `+99361000001`).

---

## 1. MySQL

Usually already running as a service. Verify:

```powershell
Get-Service *mysql*                          # should be Running
Test-NetConnection localhost -Port 3306      # TcpTestSucceeded : True
```

If stopped: `Start-Service <mysql-service-name>`.

## 2. MinIO (object storage for media, port 9000 + console 9001)

```powershell
# Credentials MUST match server/.env's MEDIA_ACCESS_KEY / MEDIA_SECRET_KEY
$env:MINIO_ROOT_USER="<MEDIA_ACCESS_KEY>"
$env:MINIO_ROOT_PASSWORD="<MEDIA_SECRET_KEY>"
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\MinIO.Server_Microsoft.Winget.Source_8wekyb3d8bbwe\minio.exe" server C:/Users/emin1/minio-data --console-address :9001
```

Leave it running. API: http://localhost:9000, web console: http://localhost:9001.
The `semay` bucket is created automatically when the server boots — no manual step.

## 3. Backend API (`server/`, port 8080)

```bash
cd c:/Users/emin1/semay/server
npm run dev            # tsx watch, hot-reloads on source changes
```

- Health check: `curl http://localhost:8080/health` → `{"ok":true,...}`.
- **OTP mode** is controlled in `server/.env`:
  - `OTP_DEV_MODE=true` → codes are logged/echoed, **no real SMS** (easiest for dev).
  - `OTP_DEV_MODE=false` → real SMS through the phone gateway (see step 6). With
    this off, the server refuses to boot unless `SMS_GATEWAY_URL/USER/PASSWORD`
    are set.
- Changing `.env` needs a full restart (Ctrl-C and `npm run dev` again) — the
  watcher only reloads source, not env.

For a production-style run instead of watch mode:
`npm run build && npm start` (runs `dist/`).

## 4. Super-Admin panel (`web-admin/`, port 3000)

```bash
cd c:/Users/emin1/semay/web-admin
npm run dev            # sync-schema + next dev
```

Open http://localhost:3000 → login with phone `+99361000001`. In dev
(`OTP_DEV_MODE=true`) the login page shows the code in an amber banner; with real
SMS it arrives on that phone.

## 5. Mobile app (release APK on a USB device)

The app already points at `http://localhost:8080` by default, reached over a USB
reverse tunnel.

```bash
ADB="/c/Android/Sdk/platform-tools/adb.exe"      # or just `adb` if on PATH
$ADB devices                                      # confirm your phone is listed

# Install the latest build:
$ADB install -r c:/Users/emin1/semay/mobile/build/app/outputs/flutter-apk/app-release.apk

# BOTH tunnels are required every time the phone connects:
$ADB reverse tcp:8080 tcp:8080     # REST + WebSocket
$ADB reverse tcp:9000 tcp:9000     # MinIO media (uploads + image/video loads)
```

To rebuild the app after code changes:
`cd mobile && flutter build apk --release --target-platform android-arm64`
(add `--dart-define=API_BASE_URL=https://api.<domain>/api/v1` only when pointing
at a deployed server instead of local).

> Reminder: media URLs are stored as `http://localhost:9000/...`, so uploaded
> photos/videos only load on a tethered phone with the `tcp:9000` tunnel up.

## 6. OTP sender — your phone (only needed when `OTP_DEV_MODE=false`)

The **SMS Gateway for Android** app (`me.capcom.smsgateway`) on the phone at
`192.168.100.74` sends the real OTP SMS. To use it:

- In the app: **Local server** ON (port 8080), **ONLINE**, "Start on boot" ON.
- `server/.env` must match the app's Local-server credentials:
  ```
  SMS_GATEWAY_URL="http://<phone-wifi-ip>:8080"
  SMS_GATEWAY_USER="sms"
  SMS_GATEWAY_PASSWORD="semaysms2026"
  OTP_DEV_MODE=false
  ```
- The **phone's Wi-Fi IP is DHCP** and can change — if OTP sends start failing,
  re-check the phone's IP (app HOME screen shows "Local address") and update
  `SMS_GATEWAY_URL`, then restart the server. A DHCP reservation or the app's
  **Cloud mode** avoids this.
- Quick gateway check (no server needed):
  ```bash
  curl -u "sms:semaysms2026" -X POST http://192.168.100.74:8080/message \
    -H "Content-Type: application/json" \
    -d '{"phoneNumbers":["+993..."],"message":"test"}'
  # 202 = accepted/sent, 401 = wrong credentials
  ```

---

## Quick start (everything already installed & seeded)

1. MinIO running (step 2).
2. `cd server && npm run dev`
3. `cd web-admin && npm run dev`
4. `adb install -r …/app-release.apk` + `adb reverse tcp:8080 tcp:8080` + `adb reverse tcp:9000 tcp:9000`
5. (only for real SMS) phone gateway ONLINE + `OTP_DEV_MODE=false`.

## Verify it's all up

- `curl http://localhost:8080/health` → ok
- `curl http://localhost:9000/minio/health/live` → 200
- http://localhost:3000/login loads
- App launches, feed loads, an OTP login completes.
