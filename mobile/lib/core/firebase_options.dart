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

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'REPLACE_ME',
    storageBucket: 'REPLACE_ME',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'REPLACE_ME',
    storageBucket: 'REPLACE_ME',
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
