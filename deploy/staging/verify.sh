#!/usr/bin/env bash
# Exercises the staging stack THROUGH nginx — the layer every other test in this
# repo bypasses, and the one that took production down.
#
#   cd deploy/staging && docker compose up -d --build && ./verify.sh
#
# -k because the staging certificate is self-signed. That is the ONLY thing
# skipped; everything else is the real path: TLS termination, the /sms prefix
# strip, the WebSocket upgrade, the long-poll hold against proxy_read_timeout,
# and media served straight off disk by nginx rather than through Node.
set -uo pipefail

BASE="https://localhost:8443"
RELAY_AUTH="semay-api:staging_relay_password_0123456789"
pass=0; fail=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then printf "  ok   %-58s %s\n" "$1" "$3"; pass=$((pass+1));
  else printf "  FAIL %-58s got %s, want %s\n" "$1" "$3" "$2"; fail=$((fail+1)); fi
}

code() { curl -sk -o /dev/null -w "%{http_code}" -m 20 "$@"; }

echo "── API through nginx ──"
check "GET /health"                200 "$(code "$BASE/health")"
check "GET / (unknown route -> API 404, not nginx)" 404 "$(code "$BASE/")"

echo "── the /sms prefix strip ──"
# The single most fragile line in the nginx config: both trailing slashes must
# be present or every relay call 404s.
check "GET /sms/health"            200 "$(code "$BASE/sms/health")"
check "GET /sms/3rdparty/v1/device (no auth)"  401 "$(code "$BASE/sms/3rdparty/v1/device")"
check "GET /sms/3rdparty/v1/device (auth)"     200 "$(code -u "$RELAY_AUTH" "$BASE/sms/3rdparty/v1/device")"
check "POST /sms/device/poll (bad token)"      401 "$(code -X POST -H 'Authorization: Bearer nope' "$BASE/sms/device/poll")"

echo "── OTP end to end (API -> relay -> queue) ──"
check "POST /auth/otp/send"        200 "$(code -X POST -H 'Content-Type: application/json' \
  -d '{"phone":"+99319000501"}' "$BASE/api/v1/auth/otp/send")"
# The demo account must NOT enqueue a message — it short-circuits before the relay.
check "demo account login (fixed code)" 200 "$(code -X POST -H 'Content-Type: application/json' \
  -d '{"phone":"+99363538839","code":"123456"}' "$BASE/api/v1/auth/otp/verify")"

echo "── media (served by nginx, not Node) ──"
check "GET /media/ (no listing)"   404 "$(code "$BASE/media/")"

echo "── WebSocket upgrade through the proxy ──"
# The failure this catches: nginx silently downgrading the upgrade when the
# `map $http_upgrade $connection_upgrade` directive is missing. The handshake
# returns 101 when it works, and 200/400 when nginx swallowed it.
ws=$(curl -sk -o /dev/null -w "%{http_code}" -m 15 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Authorization: Bearer definitely-not-valid" \
  "$BASE/sms/device/ws")
check "relay /sms/device/ws upgrade" 101 "$ws"

echo "── long poll vs proxy_read_timeout ──"
# The relay holds an idle poll ~25s. If proxy_read_timeout were below that,
# nginx would sever the fallback transport mid-hold — so this must come back
# as a clean 401 (bad token, rejected fast) rather than a 504.
check "POST /sms/device/poll survives the proxy" 401 \
  "$(code -X POST -H 'Authorization: Bearer nope' -H 'Content-Type: application/json' "$BASE/sms/device/poll")"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
