import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show kIsWeb, TargetPlatform, defaultTargetPlatform;

// TODO(phase-0-followup): This file is a placeholder. Run `flutterfire configure`
// from mobile/ against the real Firebase project to generate the actual values
// (requires the user's Firebase console login) — do not deploy with these.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  // Demo values matching the emulator suite's `--project demo-semay` — only
  // valid against the local emulator (see main.dart), never a real project.
  static const FirebaseOptions android = FirebaseOptions(
    // Must match ^AIza[0-9A-Za-z_-]{35}$ — like the appId below, the native
    // SDK (Firebase Installations) format-checks it before ANY server call,
    // including Cloud Functions callables pointed at the local emulator
    // ("Please set a valid API key" killed acceptOrder/sendOtp otherwise).
    apiKey: 'AIzaSyDemoKeyForEmulatorTesting12345678',
    // Must match ^1:\d+:android:[0-9a-f]+$ — the native SDK (Firebase
    // Installations) rejects non-hex suffixes at runtime even against the
    // emulator ("Please set your Application ID").
    appId: '1:12345678901:android:1234567890abcdef1234',
    messagingSenderId: 'demo-sender-id',
    projectId: 'demo-semay',
    storageBucket: 'demo-semay.appspot.com',
  );

  // Same demo-emulator values as Android (see the format notes there) so an
  // iOS build at least boots; run `flutterfire configure` before shipping.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDemoKeyForEmulatorTesting12345678',
    appId: '1:12345678901:ios:1234567890abcdef1234',
    messagingSenderId: 'demo-sender-id',
    projectId: 'demo-semay',
    storageBucket: 'demo-semay.appspot.com',
    iosBundleId: 'com.semay.app',
  );

  // Demo values matching the emulator suite's `--project demo-semay` — only
  // valid against the local emulator (see main.dart), never a real project.
  // Web is enabled purely so Phase 1 can be verified on this machine (no
  // Android/iOS SDK installed); run `flutterfire configure` for the real
  // project before shipping a web build.
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'demo-api-key',
    appId: 'demo-app-id',
    messagingSenderId: 'demo-sender-id',
    projectId: 'demo-semay',
    authDomain: 'demo-semay.firebaseapp.com',
    storageBucket: 'demo-semay.appspot.com',
  );
}
