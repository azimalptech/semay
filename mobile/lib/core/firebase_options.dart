import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, defaultTargetPlatform;

// The semay-b57ee Firebase project, used for FCM push ONLY — Firestore, Auth,
// Storage and Cloud Functions are gone (docs/07_MIGRATION.md). These are the
// console's per-platform app configs (Project settings → General; recorded in
// docs/09_DEPLOYMENT.md §5d). They are identifiers, not secrets: a client API
// key names the project and authorizes nothing (docs/08_OPERATIONS.md, "Checked
// and deliberately NOT changed"), so they ship in the binary — and there is no
// google-services.json / GoogleService-Info.plist anywhere, because
// Firebase.initializeApp reads these directly on every platform. Regenerate
// with `firebase apps:sdkconfig` if an app is ever re-registered
// (`flutterfire configure` needs an interactive browser login).
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
