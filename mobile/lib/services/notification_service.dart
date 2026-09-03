import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/firebase_options.dart';
import '../core/theme.dart';
import 'auth_service.dart';

// Web push needs a VAPID key, which is per-project and can't be derived from
// firebase_options.dart. Web is not a shipping target (the product is Android +
// iOS), so rather than calling getToken with a placeholder that always throws,
// registration is skipped on web unless a real key is supplied at build time:
//   flutter build web --dart-define=FCM_VAPID_KEY=...
const _webVapidKey = String.fromEnvironment('FCM_VAPID_KEY');

final messagingProvider = Provider<FirebaseMessaging>(
  (ref) => FirebaseMessaging.instance,
);

// The chat thread currently on screen, in plain synchronous memory — this is
// THE suppression for "don't banner a message from the chat I'm looking at".
// It used to be mirrored to users.activeChatId so the server could skip the
// push (and the unread increment) too, but a killed app left that flag stuck
// and the chat went permanently silent; the server no longer suppresses on
// it (see server/src/chats/service.ts sendMessage). Readable from main.dart's
// foreground handler, which runs outside any BuildContext/ProviderScope —
// same "simple global mutable flag" convention as AppColors._isDark.
String? _activeChatId;
void setLocallyActiveChatId(String? chatId) => _activeChatId = chatId;

// Anchors the in-app foreground banner (see showForegroundMessageBanner)
// outside any single screen's widget tree — main.dart wires this into
// MaterialApp.router's navigatorKey, the same "global key set up before
// runApp, used by code with no BuildContext of its own" pattern
// firebaseMessagingBackgroundHandler already relies on for Firebase itself.
// A NavigatorState's context sits above every route, which is what lets the
// banner insert itself into the *root* Overlay (so it floats above whatever
// screen is currently showing, not just the one active when it was set up)
// and resolve GoRouter.of(context) for the tap-to-open-chat navigation.
final rootNavigatorKey = GlobalKey<NavigatorState>();

// Foreground-only banner — a backgrounded/killed app gets the OS's own
// system notification for free from the FCM `notification` payload;
// foreground FCM delivery never shows anything automatically, so this is
// what stands in for it. Skipped entirely when the recipient is already
// looking straight at this exact chat (the local _activeChatId check — the
// server sends the push regardless, by design; see that flag's comment).
Future<void> showForegroundMessageBanner(RemoteMessage message) async {
  debugPrint(
    'showForegroundMessageBanner: fired data=${message.data} '
    'notification.title=${message.notification?.title} '
    'notification.body=${message.notification?.body}',
  );
  final chatId = message.data['chatId'] as String?;
  if (chatId != null && chatId == _activeChatId) {
    debugPrint(
      'showForegroundMessageBanner: suppressed, chatId=$chatId matches active chat',
    );
    return;
  }

  final title = message.notification?.title ?? '';
  final body = message.notification?.body ?? '';
  if (title.isEmpty && body.isEmpty) {
    debugPrint('showForegroundMessageBanner: suppressed, empty title+body');
    return;
  }

  // Read before the await below — a GlobalKey's currentContext, unlike a
  // widget's own context, doesn't go stale mid-async-gap under any
  // realistic scenario here (it would only become invalid if the whole app
  // were being torn down, at which point nothing in this function matters
  // anyway), but grabbing it first still means failing fast instead of
  // doing the async permission check for nothing.
  // NavigatorState.overlay directly, not Overlay.of(currentContext) — the
  // latter walks up from the navigator's own context and intermittently
  // fails to locate an ancestor Overlay mid-navigation (its null-check throws,
  // crashing the whole foreground-message stream). The navigator owns its
  // overlay, so reading it off the state is both correct and can't throw.
  final navigator = rootNavigatorKey.currentState;
  final overlay = navigator?.overlay;
  debugPrint(
    'showForegroundMessageBanner: overlay=${overlay != null ? "attached" : "NULL"}',
  );
  if (navigator == null || overlay == null) return;

  // Device-level notification permission — off means the user has
  // explicitly told the OS they don't want to be alerted, so the sound
  // (which is what actually interrupts them) respects that; the in-app
  // banner itself still shows, since that's this app's own UI, not a
  // system notification, same as e.g. an in-app toast wouldn't need OS
  // notification permission either.
  final settings = await FirebaseMessaging.instance.getNotificationSettings();
  if (settings.authorizationStatus == AuthorizationStatus.authorized ||
      settings.authorizationStatus == AuthorizationStatus.provisional) {
    SystemSound.play(SystemSoundType.alert);
  }

  _dismissForegroundBanner?.call();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _ForegroundBanner(
      title: title,
      body: body,
      onTap: () {
        _dismissForegroundBanner?.call();
        if (chatId != null) GoRouter.of(context).push('/chat/$chatId');
      },
      onDismiss: () => _dismissForegroundBanner?.call(),
    ),
  );
  _dismissForegroundBanner = () {
    if (entry.mounted) entry.remove();
    _dismissForegroundBanner = null;
  };
  overlay.insert(entry);
  // No built-in auto-dismiss on a raw OverlayEntry — hide it after a few
  // seconds like a real push notification banner, not a persistent fixture
  // the user has to manually clear.
  Future.delayed(
    const Duration(seconds: 4),
    () => _dismissForegroundBanner?.call(),
  );
}

VoidCallback? _dismissForegroundBanner;

/// Floats above whatever screen is currently showing — doesn't reserve any
/// layout space (unlike MaterialBanner, which pushes the body below it down
/// by however tall the banner is), same as how a real system notification
/// overlays instead of shoving the app's own content around.
class _ForegroundBanner extends StatefulWidget {
  const _ForegroundBanner({
    required this.title,
    required this.body,
    required this.onTap,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  State<_ForegroundBanner> createState() => _ForegroundBannerState();
}

class _ForegroundBannerState extends State<_ForegroundBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: _slide,
        child: SafeArea(
          bottom: false,
          child: Material(
            color: AppColors.backgroundCard,
            elevation: 6,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.brand,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.chat_bubble_outline,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.title.isNotEmpty)
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.bodyMediumSemibold,
                            ),
                          if (widget.body.isNotEmpty)
                            Text(
                              widget.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: widget.onDismiss,
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Marks the message the push refers to as "delivered" — the double-gray-
// check state (see chat_thread_screen.dart's _MessageBubble), meaning the
// recipient's device actually received it, independent of whether they ever
// open the thread. The server's sendChatPush attaches chatId/messageId as
// the FCM data payload specifically so this has something to write to;
// notification-only fields (title/body) carry nothing identifying which
// message this was.
Future<void> _markMessageDelivered(RemoteMessage message) async {
  final chatId = message.data['chatId'] as String?;
  if (chatId == null) return;
  try {
    // Standalone (no Riverpod/ApiClient) so it works from the background
    // isolate too — reads the stored access token directly and posts a
    // delivered receipt. The server marks every counterpart message in the
    // chat delivered (they all reached this device); best-effort, so an
    // expired token just means the thread re-marks on next open, never a
    // crash in a background isolate.
    final token = await const FlutterSecureStorage().read(key: 'access_token');
    if (token == null) return;
    await Dio().post<void>(
      '$apiBaseUrl/chats/$chatId/receipts',
      data: {'status': 'delivered'},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  } catch (e) {
    debugPrint('_markMessageDelivered failed: $e');
  }
}

// Must be a top-level (or static) function annotated exactly like this —
// FirebaseMessaging.onBackgroundMessage runs it in a separate isolate with
// no access to anything set up in main()'s isolate, so Firebase needs its
// own initializeApp() call here before any Firebase API is touched.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _markMessageDelivered(message);
}

/// Foreground counterpart to firebaseMessagingBackgroundHandler — the
/// background handler only ever fires while the app isn't already running in
/// the foreground, so this covers the rest: app open, on some other screen
/// than the message's own thread. Top-level (not an instance method) so
/// main() can register it before runApp without constructing anything that
/// needs a ProviderScope — same leak-avoidance the old code documented.
void listenForegroundMessages(void Function(RemoteMessage message) onMessage) {
  FirebaseMessaging.onMessage.listen((message) {
    debugPrint(
      'listenForegroundMessages: onMessage fired, messageId=${message.messageId}',
    );
    _markMessageDelivered(message);
    onMessage(message);
  });
}

/// Tapping a push opens its thread. Two entry points, because firebase_messaging
/// reports them differently: the app was KILLED and the tap launched it
/// (getInitialMessage — resolves once, at startup) or it was in the background
/// (onMessageOpenedApp). Neither was handled before, so a tap only brought the
/// app to whatever screen it was last on and left the user to hunt for the
/// chat — the single most common way people open a messenger. Registered from
/// main() with the app-lifetime container, like the outbox.
void listenNotificationTaps(ProviderContainer container) {
  FirebaseMessaging.instance.getInitialMessage().then((message) {
    if (message != null) _openChatFromNotification(container, message);
  });
  FirebaseMessaging.onMessageOpenedApp.listen(
    (message) => _openChatFromNotification(container, message),
  );
}

Future<void> _openChatFromNotification(
  ProviderContainer container,
  RemoteMessage message,
) async {
  final chatId = message.data['chatId'] as String?;
  if (chatId == null) return;
  debugPrint('notification tap: opening chat $chatId');
  // The router only lets a signed-in user with a completed profile past the
  // splash/auth gates — wait for that before pushing, or the redirect that
  // sends them on to the home shell would land on top of the thread. On a warm
  // app this resolves immediately.
  try {
    final profile = await container.read(userProfileProvider.future);
    if (profile == null) return;
  } catch (_) {
    return;
  }
  // One beat for the router's own redirect (splash → shell) to settle.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  if (chatId == _activeChatId) return; // already looking at it
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  GoRouter.of(context).push('/chat/$chatId');
}

class NotificationService {
  NotificationService(this._messaging, this._api);

  final FirebaseMessaging _messaging;
  final ApiClient _api;

  /// Requests permission, fetches the FCM token, and registers it with the
  /// API (POST /users/me/fcm-tokens — UNIQUE(token) upsert; see
  /// docs/07_MIGRATION.md Phase 7). Called from SeMayApp once auth resolves.
  Future<void> initAndSyncToken() async {
    try {
      // Web without a configured VAPID key can't produce a usable token — bail
      // rather than throwing on every launch (see _webVapidKey).
      if (kIsWeb && _webVapidKey.isEmpty) return;
      await _messaging.requestPermission();
      final token = kIsWeb
          ? await _messaging.getToken(vapidKey: _webVapidKey)
          : await _messaging.getToken();
      if (token == null) return;

      final platform = kIsWeb
          ? null
          : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
      final body = <String, dynamic>{'token': token};
      if (platform != null) body['platform'] = platform;
      await _api.post('/users/me/fcm-tokens', body: body);
    } catch (e) {
      debugPrint('NotificationService: token sync failed: $e');
    }
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(
    ref.watch(messagingProvider),
    ref.watch(apiClientProvider),
  );
});
