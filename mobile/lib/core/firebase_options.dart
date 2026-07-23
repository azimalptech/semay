import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, defaultTargetPlatform;

// Real values for the semay-b57ee Firebase project (fetched via
// `firebase apps:sdkconfig` after registering each platform's app —
// `flutterfire configure` needs an interactive browser login this
// environment can't do, so these were pulled directly instead). Debug
// builds still route through the local emulator regardless of these values
// (see main.dart's kDebugMode block) — only release builds actually talk to
// this real backend.
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
    apiKey: 'AIzaSyBBhT-Wy2FljkUYkm6lWB1iAI8a0bq6dJ8',
    appId: '1:185543007684:android:8330f92b64b7072011d891',
    messagingSenderId: '185543007684',
    projectId: 'semay-b57ee',
    storageBucket: 'semay-b57ee.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDL5artgZH2cgS9DwkLyG9oBDkxzsavclg',
    appId: '1:185543007684:ios:097de46705573a8d11d891',
    messagingSenderId: '185543007684',
    projectId: 'semay-b57ee',
    storageBucket: 'semay-b57ee.firebasestorage.app',
    iosBundleId: 'com.semay.semay',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDIyPUH5ft_Nru0okq-VVOJ_cUiVXYs61k',
    appId: '1:185543007684:web:025b97f3d38e2f0511d891',
    messagingSenderId: '185543007684',
    projectId: 'semay-b57ee',
    authDomain: 'semay-b57ee.firebaseapp.com',
    storageBucket: 'semay-b57ee.firebasestorage.app',
    measurementId: 'G-7FRGNS6MKK',
  );
}
