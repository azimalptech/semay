import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/firebase_options.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Local dev only — points the SDKs at `firebase emulators:start` instead of
  // a real Firebase project. .firebaserc/firebase_options.dart are still
  // placeholders, so this is required for anything to work before ship.
  if (kDebugMode) {
    // On a physical Android phone, 'localhost'/'127.0.0.1' are silently
    // rewritten to 10.0.2.2 by the FlutterFire plugins — an alias that only
    // exists inside the Android *emulator* — so every backend call would go
    // nowhere. 'Localhost' (capital L) dodges that case-sensitive rewrite
    // while still resolving to device loopback (hostname resolution is
    // case-insensitive), and loopback reaches this machine through adb port
    // forwarding — run once per device connection (physical or emulator):
    //   adb reverse tcp:9099 tcp:9099   # auth
    //   adb reverse tcp:8080 tcp:8080   # firestore
    //   adb reverse tcp:5001 tcp:5001   # functions
    //   adb reverse tcp:9199 tcp:9199   # storage
    // No same-Wi-Fi, LAN-IP, or firewall configuration is needed. To point at
    // a LAN IP anyway: flutter run --dart-define=EMULATOR_HOST=<pc-ip>
    const overrideHost = String.fromEnvironment('EMULATOR_HOST');
    final host = kIsWeb
        ? 'localhost'
        : (overrideHost.isNotEmpty ? overrideHost : 'Localhost');
    await FirebaseAuth.instance.useAuthEmulator(host, 9099);
    FirebaseFunctions.instance.useFunctionsEmulator(host, 5001);
    FirebaseFirestore.instance.useFirestoreEmulator(host, 8080);
    await FirebaseStorage.instance.useStorageEmulator(host, 9199);
  }

  runApp(const ProviderScope(child: SeMayApp()));
}

class SeMayApp extends ConsumerWidget {
  const SeMayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    ref.listen(authStateChangesProvider, (previous, next) {
      if (next.value != null) {
        ref.read(notificationServiceProvider).initAndSyncToken();
      }
    });

    return MaterialApp.router(
      title: 'SeMay',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.light,
      routerConfig: router,
      // Phone-first design: on wide viewports (desktop Chrome, tablets in
      // landscape) render inside a centered phone-width frame instead of
      // stretching 393px-designed layouts across the full window.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth <= 600) return child;
            return ColoredBox(
              color: const Color(0xFF1F1D1B),
              child: Center(
                child: ClipRect(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
