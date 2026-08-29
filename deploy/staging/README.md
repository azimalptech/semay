# deploy/staging — a local stand-in for the production box

Everything else in this repo tests the API by talking to Node directly. The one
layer that never got exercised is the one that actually took production down:
**nginx** — TLS termination, the `/sms/` prefix strip, the WebSocket upgrade,
and the long-poll timeout. Those failures are invisible from a direct-to-Node
test by construction, which is why a fully green suite sat alongside a site
that would not serve a request.

This brings that layer up locally so a mistake in it fails here instead.

## Prerequisites

Docker Desktop with the WSL2 backend. If `docker info` errors and
`wsl --version` prints nothing, WSL is not installed:

```powershell
# admin PowerShell, then reboot
wsl --install
```

If Docker still refuses with **"Virtualization support not detected"**, the CPU
flag is off in firmware — check `(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled`.
`False` means Intel VT-x / AMD-V is disabled in the BIOS and no amount of
software setup will help. Use the no-Docker path below instead.

## Without Docker

The whole point is exercising nginx, and nginx does not need a VM. Run it
natively in front of the two services started from the host:

1. Download nginx for Windows from <https://nginx.org/en/download.html>
   (1.24.x, matching production) and unzip it.
2. Start the API and the relay on **8070** and **8071**, each with its own
   `--env-file`. `MEDIA_PUBLIC_BASE_URL` must be `https://localhost:9443/media`
   — `config.ts` refuses to boot on an `http` value for a non-loopback host.
3. Use `nginx.conf` from this directory with three edits: `listen 9443 ssl`,
   upstreams pointed at `127.0.0.1:8070` / `:8071`, and the `alias` in
   `location /media/` pointed at `server/media/`.
4. `nginx.exe -t -p <dir>` to check, then `nginx.exe -p <dir>` to run.

Everything that governs proxy behaviour — the `map`, both trailing slashes on
`/sms/`, the upgrade headers, the timeouts — is identical, so this tests the
same things the compose stack does. Only TLS uses a self-signed certificate and
MySQL is the host's rather than a container's.

**Verified this way on 2026-08-29** against real nginx 1.24.0: all HTTP checks
passed, the WebSocket handshake returned 101 through the proxy, and an
authenticated idle long-poll was held open for 25.1s and returned 200 rather
than being severed. Both fragile directives were then negative-tested — removing
the `proxy_pass` trailing slash produced a 404, and replacing
`$connection_upgrade` with `""` broke the upgrade — confirming the checks fail
when the config is wrong, rather than passing vacuously.

## Run

```bash
cd deploy/staging
docker compose up -d --build     # first build takes a few minutes
./verify.sh
```

`verify.sh` drives the stack through nginx and checks the things that broke, or
nearly broke, in production:

| Check | The failure it catches |
|---|---|
| `/sms/health` → 200 | A missing trailing slash on `location /sms/` or `proxy_pass`, which 404s every relay call |
| `/sms/device/ws` → **101** | A missing `map $http_upgrade $connection_upgrade`. nginx then silently downgrades the upgrade and the handset falls back to polling — which still works, so nobody notices until they wonder why the socket never connects |
| `/sms/device/poll` → 401 not 504 | `proxy_read_timeout` below the relay's 25s long-poll hold, severing the fallback transport |
| `/health` → 200, `/` → 404 | The API location proxying with a trailing slash and mangling paths |
| demo login with the fixed code | `OTP_TEST_PHONE` wiring, end to end |

Ports are deliberately non-standard (`8443` for TLS, `8081` for the panel) so
this cannot collide with anything already running on the host.

## Deliberate differences from production

Kept as few as possible, because each one is a place a bug could hide:

- **Self-signed certificate** — `verify.sh` passes `-k`. That is the only check
  skipped.
- **Upstreams are compose service names** (`api:8080`, `relay:8081`) rather than
  `127.0.0.1`. Same directives otherwise.
- **MySQL lives in tmpfs** — staging data is disposable, and a reset should not
  inherit the previous run's rows.
- **`OTP_DEV_MODE=true`** — no SMS gateway is attached, and staging must never
  be able to send a real message.

`nginx.conf` is otherwise a directive-for-directive mirror of
`deploy/nginx/semaycollection.com.conf`. Keep them in step: when one changes,
change the other, or this stops testing what it claims to.

## Reset

```bash
docker compose down -v && docker compose up -d --build
```
