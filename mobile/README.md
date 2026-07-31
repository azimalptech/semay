# mobile/

Flutter app for both roles (User + Store Admin, one codebase, branched on the role
claim). Talks to `server/` over REST + one multiplexed WebSocket. Firebase is
present for **FCM push only** — no Firestore, Auth, Storage, or Functions.

## Requirements

| Tool | Version | Notes |
|---|---|---|
| Flutter | **3.44.8+** | `pubspec.yaml` needs Dart `^3.11.4`; Flutter 3.24 ships Dart 3.5 and will not resolve |
| Android SDK | Platform 36 + Build-Tools 35.0.0 | plus `cmdline-tools`, see below |
| JDK | 17–22 | AGP 8.11.1 targets Java 17 |

## Android SDK setup (one-time)

`flutter doctor` must show **`[√] Android toolchain`** before a build can succeed.
Two things are easy to miss, and both make a build hang or fail confusingly:

1. **`cmdline-tools` must be installed.** Without it there is no `sdkmanager`, so
   Gradle cannot install SDK components it needs — it stalls indefinitely with no
   error rather than telling you what is missing. Download
   "Command line tools only" from <https://developer.android.com/studio#command-line-tools-only>
   and unzip so that `sdkmanager` lands at
   `%LOCALAPPDATA%\Android\sdk\cmdline-tools\latest\bin\sdkmanager.bat`.

2. **Licenses must be accepted**, or component installs fail mid-build:
   ```bash
   sdkmanager --licenses          # answer y to each
   sdkmanager "platforms;android-36" "build-tools;35.0.0"
   ```
   Installing these explicitly is more reliable than letting Gradle do it.

If a build was interrupted while downloading an SDK package, delete
`%LOCALAPPDATA%\Android\sdk\.temp` before retrying — a leftover partial unzip
causes `FileAlreadyExistsException` on the next attempt.

## Build

```bash
flutter pub get
flutter analyze          # must be clean
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`. The first build is slow
(~10 min) while Gradle downloads dependencies; later builds are far faster.

## Debugging on a physical device

The app defaults to `http://localhost:8080/api/v1`. On a real device, `localhost`
is the phone — so tunnel it back to your machine:

```bash
adb reverse tcp:8080 tcp:8080     # re-run after every reconnect
cd ../server && npm run dev       # in another terminal
cd ../mobile && flutter run
```

Cleartext HTTP over loopback is permitted for exactly this
(`android/app/src/main/res/xml/network_security_config.xml`); every non-loopback
host still requires TLS, in debug and release alike.

To point at a deployed API instead:

```bash
flutter run --dart-define=API_BASE_URL=https://api.example.com/api/v1
```

## Push notifications

`lib/core/firebase_options.dart` holds the real `semay-b57ee` config, and
`Firebase.initializeApp(options: …)` uses it directly — the
`com.google.gms.google-services` Gradle plugin is deliberately **not** applied, so
no `google-services.json` is needed or read. (A placeholder one for a
non-existent `demo-semay` project used to sit in `android/app/` doing nothing; it
was deleted.)

Server-side push needs `server/serviceAccount.json`; without it the API logs
`FCM push is DISABLED` at boot and runs normally with push off.

Web push is not supported: it needs a VAPID key, which is per-project and not in
`firebase_options.dart`. Registration is skipped on web unless you supply one via
`--dart-define=FCM_VAPID_KEY=…`.

## Gotcha: `dependency_overrides` is load-bearing

`firebase_messaging` 16.4.2 declares `firebase_core_platform_interface ^7.1.0` but
its compiled code extends `FirebasePlugin`, which only exists from 8.0.0. The
override in `pubspec.yaml` pins 8.0.0. **`flutter pub get` succeeds without it** —
the failure only appears at compile time as `Type 'FirebasePlugin' not found`. Do
not remove it without running a full Android build.
