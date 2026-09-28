# 10 — Release history

Every build that reaches a store gets a row here, **in the same change that bumps
the version**. The cost of skipping that: nobody recorded what Android 1.0.0 was
built from, and recovering it took a byte-level comparison of the app Play
serves against old build output (see below). A first guess from commit dates was
wrong by four commits.

## Version numbers

`mobile/pubspec.yaml` → `version: X.Y.Z+N`

| Part | Android | iOS | Seen by users |
|---|---|---|---|
| `X.Y.Z` | `versionName` | `CFBundleShortVersionString` | yes |
| `N` | `versionCode` | `CFBundleVersion` (build) | no |

- **`N` only ever goes up, and it is shared.** Each store refuses a number it has
  already accepted. A build that fails *upload validation* (e.g. Apple 90474) was
  never registered and does not use up its number; anything that uploaded
  successfully does, even if it is later rejected in review.
- **The same label can mean different code on each store.** The two stores are
  released independently. See iOS 1.0.0 below.
- A release build must carry the production API origin:
  `--dart-define=API_BASE_URL=https://semaycollection.com/api/v1`. Without it the
  app falls back to `http://localhost:8080`, which on a phone is the phone.

---

## Android — Google Play

Package `com.semay.semay`. Always uploaded as an **App Bundle (`.aab`)** — Play
does not accept APKs for this app. APKs are only for sideloading onto a test phone.

| Version | versionCode | Built from | Built | Status |
|---|---|---|---|---|
| 1.0.0 | 1 | `3d8fffd` | 2026-09-02 22:39 | **Live.** On the test phone from Play (`installer=com.android.vending`) since 2026-09-09. |
| 1.1.0 | 2 | `66ea3f6` + the version bump that adds this row | 2026-09-28 14:26 | **Built and verified, awaiting upload** by the owner. |

**How 1.0.0's source was established:** the bundle Play serves was pulled off the
test phone with `adb` and compared with `build-out/android/semay-1.0.0.aab`
(git-ignored, still on the build machine). `libapp.so` (all compiled Dart) and
`classes.dex` are byte-identical — SHA-256 `245ee2a2…94eee` and `c58c110a…ed745`.
That bundle was written three minutes after `3d8fffd` was committed, carries
`3d8fffd`'s launcher icon, and contains none of the strings that `8979883` (the
next app commit) introduced.

### 1.1.0 — changes since 1.0.0

Everything below is new to Play users; 1.1.0 is the first Play release after
`3d8fffd`.

**Chat**
- Real-time delivery made reliable: messages no longer stop arriving after a
  while, the connection recovers on its own, and push notifications for new
  messages arrive (Phases 9c and later fixes).
- Chats are cached on the phone, so they open instantly and stay readable
  offline; scrolling up loads older history.
- Photos and videos in chat go through an outbox: a bad connection or an app
  restart no longer loses them, and they retry on their own.
- Message status follows Instagram: Sending… → Sent → Seen, and "Not sent" with
  retry. Typing indicator; in-app banner for new messages.
- Unread counts and read receipts for shop conversations fixed.
- Pull-to-refresh on the chat list; the composer grows with multi-line text;
  larger, messenger-scale type; the inbox date is localised (tk/ru).
- Deleting a chat hides its earlier history.

**Everything else**
- All times are shown in the phone's local time (they were 5 hours off).
- Reels appear in the main feed; reel audio stops when you leave the reel; a view
  is counted after 0.8 s.
- Store admins can create quick replies.
- Upload progress shown as a percentage, with a success or failure notice.
- Sharing fixed; links open the app (`semay://` scheme, and
  `https://semaycollection.com/p|r|s/…` App Links — see *Known issue* below).
- Notification channels are created at process start by a custom `Application`
  class, so a push that arrives right after a Play update still lands in the
  right channel. Only permission added: `VIBRATE` (normal, no declaration).
- Profile editing gives feedback; the story ring only shows when there is an
  active story; liked, saved and four other lists refresh instead of loading
  once per launch.
- Sessions last until logout instead of expiring.

App commits: `de40a6e`, `8979883`, `8d435c3`, `4eb2e4c`, `c50207b`, `a0aa6ca`,
`6f1c4ad`, `98fd704`, `5dc4c9a`. The later `d9fc09d`…`66ea3f6` are iOS/CI-only
and do not change the Android app.

**Server:** many of these commits also change the server. As of 2026-09-28 the
production API and WebSocket answer as 1.1.0 expects (verified from outside:
REST routes return 401 without a token, `/api/v1/ws` upgrades with `101`).

**Known issue — App Links will not verify yet.** 1.1.0 is the first build that
asks Android to verify `https://semaycollection.com` and `www.` links. Production
nginx currently serves the static landing page for everything outside
`/api/v1`, including `/.well-known/assetlinks.json` and the `/p|r|s/<id>` share
pages, and the TLS certificate does not cover `www.semaycollection.com`. Not a Play rejection and
nothing from 1.0 breaks: shared https links open the browser instead of the app.
To fix, on the server: deploy `deploy/nginx/semaycollection.com.conf` (it proxies
`/` to the API), set `SHARE_ANDROID_CERT_SHA256` to the **app signing**
certificate below, and reissue TLS for both hosts. Android re-checks on
install/update; `adb shell pm get-app-links com.semay.semay` shows the result.
Details: `docs/09_DEPLOYMENT.md` §5e.

**Pre-release verification, 2026-09-28:**
- `flutter analyze` clean; `flutter test` 242/242.
- Release gate run against the built bundle itself, not the config: versionCode
  2 > 1, versionName 1.1.0, package unchanged, not debuggable/testOnly;
  targetSdk 36 (Play's requirement since 2026-08-31); every native library
  16 KB-aligned; AOT release build with the production origin compiled in and no
  `localhost` fallback; Firebase project `semay-b57ee`, same app id and sender as
  1.0; cleartext only to localhost, as in 1.0. Upgrade from 1.0 checked: local
  databases keep their schema, session keys unchanged, notification channels are
  created fresh (1.0 never created any), Gson generic signatures survive R8.

### Signing

- **Upload key:** `mobile/android/semay-release.jks` (alias `semay`), wired
  through `mobile/android/key.properties`. Both are git-ignored — keep an offline
  backup. Losing the upload key means a Google support request to reset it.
  - Upload certificate SHA-1 `69:4E:FC:04:AC:A0:B5:47:22:B8:D9:02:9B:94:27:69:B9:FD:1A:1A`
  - SHA-256 `C7:6E:46:35:A8:EB:38:E6:FA:B3:11:17:65:D9:F3:BE:8A:4C:99:62:3D:A9:87:C1:07:35:EE:AB:EE:C9:69:DD`
  - Same key signed the 1.0.0 bundle, the Sep 17 sideloaded APKs and 1.1.0.
  - Must equal Play Console → *Test and release* → *App integrity* → *Upload key
    certificate*.
- **App signing key (Google's, Play App Signing).** What users actually download
  is re-signed with it, so this — not the upload key — is what
  `/.well-known/assetlinks.json` must list (`SHARE_ANDROID_CERT_SHA256`):
  - SHA-256 `76:28:76:73:57:27:5E:76:E5:BD:D9:A0:CB:DE:5A:B4:F2:1A:54:BC:19:E3:F0:60:CC:25:EB:C5:8D:37:E1:07`
  - Read from the APK Play installed; should match *App signing key certificate*
    on the same Console page.
- **Trap:** if `key.properties` is missing, `android/app/build.gradle.kts` falls
  back to the **debug** key without an error, and Play rejects the bundle. Check
  the signer of the built file (`keytool -printcert -jarfile app-release.aab`),
  not the config.

### How to build

```bash
cd mobile
flutter build appbundle --release --dart-define=API_BASE_URL=https://semaycollection.com/api/v1
```

Output: `mobile/build/app/outputs/bundle/release/app-release.aab`. Keep a copy
per release (e.g. `build-out/android/semay-<version>.aab`) — it is what made
1.0.0's source recoverable.

If `flutter test` fails with every file saying *"Connection closed before test
suite loaded"* / *WebSocket … HTTP status code: 503*, nothing is wrong with the
tests: a local VPN proxy in `HTTP_PROXY` is intercepting the test runner's
connection to itself. Add `localhost,127.0.0.1` to `no_proxy`.

---

## iOS — App Store

App Store Connect app **"Semay Collection"**, Apple ID `6814409437`, bundle
`com.semay.semay`, team `48VJ8XUY5W`. **iPhone only.**

| Version | Build | Built from | Uploaded | Status |
|---|---|---|---|---|
| 1.0.0 | 1 | `66ea3f6` | 2026-09-21 | **Uploaded** to App Store Connect (delivery `0744a48b-2ac9-4df3-a9fc-08524a38649b`), Codemagic build `6ab13acd31c4754eb6d4937e`. Submission for review is the owner's step. |

**iOS 1.0.0 already contains every app change listed under Android 1.1.0** — it
was built from `66ea3f6`, after all of them. Same code, different label.

Attempts that did not use up a build number:

| Codemagic build | Outcome |
|---|---|
| `6ab0f852061208102072a7f3` | Cancelled before publishing — the owner decided CI must not publish on its own. |
| `6ab0fa13f6e84f832c4ad830` | Signed `.ipa` produced, not uploaded (no publishing step at the time). Build 1, so it can no longer be uploaded. |
| `6ab1363280e9ed35a9c9109b` | Rejected at upload validation, **error 90474**: the bundle claimed iPad support with only portrait orientation. Fixed in `66ea3f6` (iPhone only). |

The next iOS build from the current `pubspec.yaml` is **1.1.0 (2)**. App Store
Connect only attaches it to a *1.1* version record, not to 1.0.

### Signing and upload

- Built and uploaded by Codemagic, workflow `ios-appstore` in `codemagic.yaml`:
  **uploads, submits nothing** (`submit_to_testflight: false`,
  `submit_to_app_store: false`). There is no Windows uploader — Transporter and
  Xcode are macOS-only — so CI is the upload path.
- Distribution certificate private key: Codemagic secret
  `CERTIFICATE_PRIVATE_KEY` in variable group `ios_signing`, imported by both
  signed workflows. A copy is kept off-repo by the owner. Without it every build
  asks Apple for a new certificate and hits the cap of two.
- `Info.plist`: `ITSAppUsesNonExemptEncryption = false` (HTTPS only, no bundled
  crypto) so uploads are not held as "Missing Compliance"; no
  `UISupportedInterfaceOrientations~ipad` and `TARGETED_DEVICE_FAMILY = "1"` — see
  the comment in `Info.plist` before adding iPad back.

---

## Before submitting any update for review

Both stores re-review updates, and SeMay requires login. Review only works while
the demo OTP bypass is live on production (`OTP_TEST_PHONE` / `OTP_TEST_CODE` in
`server/.env`, and the account's role still plain `user` — the server refuses
the bypass otherwise). Log in once with the demo account against production
before submitting, and make sure the store's review-access section lists it
(Play: *App content* → *App access*; Apple: *App Review Information* → *Sign-In
Required*). See `docs/09_DEPLOYMENT.md` → *Demo account*.
