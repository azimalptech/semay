import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/firebase_options.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'core/theme_provider.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait-only — the whole design (post-composer, feed, reels, chat) is
  // phone-portrait-first with no landscape layouts. AndroidManifest.xml's
  // MainActivity screenOrientation and iOS's Info.plist
  // UISupportedInterfaceOrientations already lock this natively (so there's
  // no flash of landscape before Flutter loads); this is the Dart-side
  // backstop, mainly for web, which ignores both native manifests.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Must be registered here, before runApp — this is what lets a chat
  // message's deliveredAt (see notification_service.dart's
  // firebaseMessagingBackgroundHandler) get marked even while the app is
  // fully backgrounded or killed, not just while it's open.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

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

  // Registered exactly once here, not inside SeMayApp.build() — that method
  // re-runs on every rebuild, and .listen() on a raw Stream (unlike
  // Riverpod's ref.listen, which dedupes across rebuilds) creates a brand
  // new subscription each time, so calling this from build() would leak
  // an ever-growing pile of listeners and eventually fire
  // _markMessageDelivered many times over for one message.
  NotificationService(
    FirebaseMessaging.instance,
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  ).listenForegroundMessages(showForegroundMessageBanner);

  runApp(const ProviderScope(child: SeMayApp()));
}

class SeMayApp extends ConsumerWidget {
  const SeMayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final isDark = ref.watch(darkModeProvider);
    // AppColors' getters (see theme.dart) read this flag directly rather
    // than through Theme.of(context) — setDark() alone doesn't trigger any
    // rebuilds by itself, so the ValueKey below is what actually makes
    // already-built widgets repaint: it forces the whole MaterialApp
    // subtree to be torn down and rebuilt from scratch when the flag flips,
    // the same one-time-cost trick used to work around not having a proper
    // InheritedWidget-based theme for these colors.
    AppColors.setDark(isDark);

    ref.listen(authStateChangesProvider, (previous, next) {
      if (next.value != null) {
        ref.read(notificationServiceProvider).initAndSyncToken();
      }
    });

    return MaterialApp.router(
      key: ValueKey(isDark),
      title: 'SeMay',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
      // Phone-first design: on wide viewports (desktop Chrome, tablets in
      // landscape) render inside a centered phone-width frame instead of
      // stretching 393px-designed layouts across the full window.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        // App-wide tap-outside-to-dismiss-keyboard — one wrapper here covers
        // every screen instead of adding it piecemeal per text field.
        // `translucent` (not `opaque`) so it never blocks a descendant's own
        // tap handling; it just also unfocuses whenever a tap lands anywhere,
        // which is a harmless no-op when nothing's focused.
        final dismissKeyboard = GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          behavior: HitTestBehavior.translucent,
          child: child,
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth <= 600) return dismissKeyboard;
            return ColoredBox(
              color: const Color(0xFF1F1D1B),
              child: Center(
                child: ClipRect(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: dismissKeyboard,
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
