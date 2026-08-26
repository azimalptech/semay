# sms-gateway/

Self-hosted SMS relay for SeMay OTP delivery. Replaces the dependency on
`api.sms-gate.app`, which is **unreachable from Turkmen networks** (verified:
100% packet loss from the gateway handset, while `semaycollection.com` answers
in 13ms from the same phone on the same Wi-Fi).

```
SeMay API ──HTTP──► sms-gateway (this) ──WebSocket──► Android sender app(s) ──► SMS
   sms.ts            on semaycollection.com           one per SIM / dual-SIM
```

## The one design rule

**The 3rd-party HTTP API is byte-compatible with sms-gate.app.** Same paths,
same Basic auth, same JSON shapes:

```
POST /3rdparty/v1/message      {phoneNumbers: [...], message: "..."} -> {id, state, recipients}
GET  /3rdparty/v1/message/:id  -> {id, state, states, recipients}
GET  /3rdparty/v1/device       -> [{id, name, lastSeen, simCards}]
```

That is deliberate, and it buys three things:

1. `server/src/auth/sms.ts` needs **no code change** — it already POSTs to
   `${SMS_GATEWAY_URL}/message` with Basic auth. Switching gateways is one
   `.env` edit.
2. Rollback is instant. If this relay misbehaves, point `SMS_GATEWAY_URL` back
   at the old gateway and nothing else moves.
3. Both can run side by side during migration.

Do not "improve" these three endpoints' shapes. Add new endpoints under a
different prefix instead.

## Why not just self-host sms-gate.app's own relay

That was the cheaper option and it was considered. This exists because the
owner wants the delivery path owned end to end — no foreign dependency that
can be blocked, deprecated, or rate-limited. The tradeoff accepted: we now
maintain an Android app and a relay.

## Scaling model: SIMs, not servers

Throughput is bounded by SIM cards, not CPU. One SIM sends roughly one SMS
every few seconds before carriers start flagging it as A2P traffic, so
capacity grows by adding handsets:

- 1 phone, 1 SIM = 1 sender
- 1 dual-SIM phone = 2 senders
- N phones = 2N senders

The relay round-robins across every enabled SIM that is online and under its
rate cap, so adding a phone is plug-in-and-register with no config change.

**Per-SIM rate limits are not optional.** A consumer SIM blasting OTP codes
gets blocked by the carrier, and the failure looks exactly like "our app is
broken" to every user trying to log in. `SIM_MAX_PER_HOUR` / `SIM_MAX_PER_DAY`
exist to keep each SIM inside plausible human-ish volume.

## Delivery guarantees

OTP is **at-most-once by preference, never silently dropped**:

- A message is `Pending` until a device claims it, `Assigned` while in flight,
  then `Sent` (radio accepted it) and `Delivered` (carrier receipt).
- If a device goes offline mid-flight, the message is reassigned to another SIM
  after `ASSIGN_TIMEOUT_SECONDS` rather than waiting for a phone that may never
  come back.
- Reassignment is capped at `MAX_ATTEMPTS`. An OTP that took 4 minutes to
  arrive is worse than useless — the code has already expired server-side
  (`OTP_TTL_SECONDS`, 5 min) — so exhausted messages fail loudly instead of
  arriving late.

## Components

| Path | What |
|---|---|
| `src/routes/thirdparty.ts` | The compatible API above. Basic auth. |
| `src/routes/device.ts` | Device registration + WebSocket work channel + status reports. Bearer auth. |
| `src/dispatch.ts` | SIM selection, rate limiting, reassignment. |
| `android/` | The sender app. Foreground service, `SmsManager`, per-subscription (dual-SIM) sending. |

## Android app: the two things that will bite

1. **`SEND_SMS` is a restricted permission.** Google Play rejects apps
   requesting it unless the app *is* the user's default SMS handler. This app
   is therefore **sideloaded**, not published. Plan for APK distribution, not
   a Play listing.
2. **Doze will kill a background socket.** The app runs a foreground service
   with a persistent notification and must be exempted from battery
   optimisation on every handset. The current failure mode on the existing
   gateway phone — process alive, relay connection dead for ~an hour — is
   exactly this.
