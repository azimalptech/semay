import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/firebase_options.dart';
import 'core/interaction_buffer.dart';
import 'core/outbox.dart';
import 'core/realtime_client.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'core/theme_provider.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/posts_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait-only — the whole design (post-composer, feed, reels, chat) is
  // phone-portrait-first with no landscape layouts. AndroidManifest.xml's
  // MainActivity screenOrientation and iOS's Info.plist
  // UISupportedInterfaceOrientations already lock this natively (so there's
  // no flash of landscape before Flutter loads); this is the Dart-side
  // backstop, mainly for web, which ignores both native manifests.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Firebase is now used for FCM push ONLY (all data moved to the self-hosted
  // API — see docs/07_MIGRATION.md). initializeApp is still required for
  // firebase_messaging; the REST/WS backend is reached via API_BASE_URL (a
  // --dart-define, default http://localhost:8080/api/v1) over one
  // `adb reverse tcp:8080 tcp:8080` on a physical device.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Registered before runApp so a chat message's deliveredAt (see
  // notification_service.dart's firebaseMessagingBackgroundHandler) gets
  // marked even while the app is fully backgrounded or killed.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  // iOS: a push that arrives while the app is in the FOREGROUND is otherwise
  // presented with nothing at all — which also discards its badge number. The
  // in-app banner covers alert/sound; the badge has to be let through, or the
  // badge-only correction the server sends after a read never reaches the
  // icon and it keeps the last background-applied count. No-op on Android.
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    badge: true,
  );

  // Registered exactly once here, not inside SeMayApp.build() — a raw
  // Stream.listen (unlike Riverpod's ref.listen) creates a fresh subscription
  // per rebuild, so calling this from build() would leak listeners. Top-level
  // function now (see notification_service.dart), no service instance needed.
  listenForegroundMessages(showForegroundMessageBanner);

  // The offline outbox + interaction buffer each need one container living for
  // the app's lifetime so their SQLite queues start now (outbox reconnect drain,
  // buffer 30-min flush) and the SAME instances are shared with the widget tree.
  final container = ProviderContainer(
    overrides: [
      // The outbox uploads queued chat media through the same signed-URL path
      // posts use. Wired here, lazily, because PostsService itself depends on
      // the outbox (like/save toggles) — see MediaUploader in outbox.dart.
      outboxUploaderProvider.overrideWith(
        (ref) =>
            ({required folder, required bytes, required fileExt, required contentType}) =>
                ref.read(postsServiceProvider).uploadMedia(
                  folder: folder,
                  bytes: bytes,
                  fileExt: fileExt,
                  contentType: contentType,
                ),
      ),
    ],
  );
  unawaited(container.read(outboxServiceProvider).start());
  unawaited(container.read(interactionBufferProvider).start());
  // Tap on a push → open that chat (both the cold-start and background cases).
  listenNotificationTaps(container);

  // Flush buffered view/send/share counts the moment the app is backgrounded or
  // closed, not only on the 30-min tick — otherwise a session shorter than the
  // interval would lose its counts. Held in a top-level ref so it isn't GC'd.
  //
  // On resume: probe the realtime socket (the OS may have silently killed it
  // while we were in the background — see realtime_client.dart) and drain the
  // outbox, so anything typed just before the screen locked goes out now
  // rather than on the next connectivity event.
  _lifecycleListener = AppLifecycleListener(
    onPause: () => unawaited(container.read(interactionBufferProvider).flush()),
    onDetach: () => unawaited(container.read(interactionBufferProvider).flush()),
    onResume: () {
      unawaited(container.read(realtimeClientProvider).checkConnection());
      unawaited(container.read(outboxServiceProvider).drain());
    },
  );

  runApp(
    UncontrolledProviderScope(container: container, child: const SeMayApp()),
  );
}

// ignore: unused_element -- retained for its lifecycle side effects (see above).
AppLifecycleListener? _lifecycleListener;

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
