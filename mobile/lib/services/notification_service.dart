import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/firebase_options.dart';
import 'auth_service.dart';

// Web push needs a VAPID key, which is per-project and can't be derived from
// firebase_options.dart. Web is not a shipping target (the product is Android +
// iOS), so rather than calling getToken with a placeholder that always throws,
// registration is skipped on web unless a real key is supplied at build time:
//   flutter build web --dart-define=FCM_VAPID_KEY=...
const _webVapidKey = String.fromEnvironment('FCM_VAPID_KEY');

// Android notification channels, created at IMPORTANCE_HIGH by MainActivity.kt
// (ids and names must match there and on the server: CHAT_PUSH_CHANNEL in
// chats/service.ts, BROADCAST_PUSH_CHANNEL in notifications/service.ts). A
// backgrounded app's push lands on them via FCM; a foreground one is posted
// here on the same channel, so the user's per-channel settings apply to both.
const _chatChannelId = 'chat_messages';
const _chatChannelName = 'Messages';
const _announcementsChannelId = 'announcements';
const _announcementsChannelName = 'Announcements';

final messagingProvider = Provider<FirebaseMessaging>(
  (ref) => FirebaseMessaging.instance,
);

// The chat thread currently on screen, in plain synchronous memory — this is
// THE suppression for "don't notify about a message from the chat I'm looking
// at". It used to be mirrored to users.activeChatId so the server could skip
// the push (and the unread increment) too, but a killed app left that flag
// stuck and the chat went permanently silent; the server no longer suppresses
// on it (see server/src/chats/service.ts sendMessage). Readable from the
// foreground handler below, which runs outside any BuildContext/ProviderScope
// — same "simple global mutable flag" convention as AppColors._isDark.
String? _activeChatId;
void setLocallyActiveChatId(String? chatId) => _activeChatId = chatId;

// Anchors notification-tap navigation outside any single screen's widget tree
// — router.dart wires this into MaterialApp.router's navigatorKey, the same
// "global key set up before runApp, used by code with no BuildContext of its
// own" pattern firebaseMessagingBackgroundHandler already relies on for
// Firebase itself. A NavigatorState's context sits above every route, which is
// what lets GoRouter.of(context) resolve from a push handler.
final rootNavigatorKey = GlobalKey<NavigatorState>();

// What a push is about, read off its data payload. The server sets `type`
// ('chat_message' with a chatId, or 'broadcast'); anything else — an order
// notice, say — has nowhere to route and no channel of its own.
class _PushKind {
  _PushKind(Map<String, dynamic> data)
    : chatId = data['chatId'] as String?,
      isBroadcast = data['type'] == 'broadcast';

  final String? chatId;
  final bool isBroadcast;
}

final _localNotifications = FlutterLocalNotificationsPlugin();

// Only Android posts its own foreground notification. firebase_messaging hands
// a push that arrives while the app is open to Dart and shows nothing — the
// heads-up a backgrounded app gets for free from the `notification` payload
// never appears — so the app posts it itself. iOS is the other way round: the
// OS presents a foreground push itself once main.dart asks it to
// (setForegroundNotificationPresentationOptions), and a local copy on top of
// that would show two banners for one message.
bool get _postsForegroundNotifications =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// A push that arrives while the app is OPEN. Registered exactly once from
/// main() with the app-lifetime container, after the plugin is ready — a raw
/// Stream.listen (unlike Riverpod's ref.listen) creates a fresh subscription
/// per call, so this must never run from a build(). `onBroadcast` is how the
/// inbox learns a new row exists: the notifications list is REST-only
/// (notifications_providers.dart) and this is the one moment the app knows to
/// refetch it, so the bell badge updates without a restart.
Future<void> setUpForegroundNotifications(
  ProviderContainer container, {
  required VoidCallback onBroadcast,
}) async {
  if (_postsForegroundNotifications) {
    await _localNotifications.initialize(
      settings: const InitializationSettings(
        // A dedicated monochrome status-bar glyph, NOT the launcher icon: on
        // API 26+ @mipmap/ic_launcher resolves to an adaptive icon, which
        // Android 8.0 rejects as a notification small icon (RemoteService-
        // Exception "Bad notification posted" — the process dies) and later
        // versions flatten to a blob. FCM's own SDK guards against that; this
        // plugin does not. The manifest points FCM at the same drawable so a
        // background delivery looks identical.
        android: AndroidInitializationSettings('@drawable/ic_notification'),
      ),
      onDidReceiveNotificationResponse: (response) =>
          _openFromPayload(container, response.payload),
    );
    // The notification was posted while the app was open, the app has since
    // been killed, and its tap is what launched us — the plugin reports that
    // here rather than through the callback above (which needs a live app).
    final launch = await _localNotifications.getNotificationAppLaunchDetails();
    if (launch != null && launch.didNotificationLaunchApp) {
      _openFromPayload(container, launch.notificationResponse?.payload);
    }
  }
  FirebaseMessaging.onMessage.listen((message) {
    debugPrint(
      'foreground push: messageId=${message.messageId} data=${message.data}',
    );
    _markMessageDelivered(message);
    final kind = _PushKind(message.data);
    if (kind.isBroadcast) onBroadcast();
    _showForegroundNotification(message, kind);
  });
}

// Android's system notification for a foreground push — the same channel, tag
// and (id 0) identity FCM's own Android SDK uses for a background delivery, so
// a chat that already has a notification in the shade gets it REPLACED rather
// than a second one stacked next to it. A push with no collapse identity (an
// order notice: no chatId, no type) gets no tag and its own id instead, so it
// stacks the way FCM's background delivery does — with tag 'broadcast' it
// would silently overwrite a pending announcement, and vice versa. Skipped
// entirely when the recipient is already looking straight at this exact chat
// (the local _activeChatId check — the server sends the push regardless, by
// design; see that flag).
Future<void> _showForegroundNotification(
  RemoteMessage message,
  _PushKind kind,
) async {
  if (!_postsForegroundNotifications) return;
  if (kind.chatId != null && kind.chatId == _activeChatId) {
    debugPrint('foreground push: suppressed, chat ${kind.chatId} is on screen');
    return;
  }
  final title = message.notification?.title ?? '';
  final body = message.notification?.body ?? '';
  if (title.isEmpty && body.isEmpty) return;

  final channelId = kind.isBroadcast ? _announcementsChannelId : _chatChannelId;
  final channelName = kind.isBroadcast
      ? _announcementsChannelName
      : _chatChannelName;
  final tag = kind.chatId ?? (kind.isBroadcast ? 'broadcast' : null);
  await _localNotifications.show(
    // messageId is set by FCM's Android SDK on every delivery; its String
    // hashCode fits the 32-bit id the plugin requires.
    id: tag == null ? message.messageId.hashCode : 0,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        // Matches the channel MainActivity.kt created; the plugin would
        // otherwise create a default-importance one under the same id on a
        // device where the activity has not run yet, and a channel's
        // importance is fixed at creation.
        importance: Importance.high,
        priority: Priority.high,
        tag: tag,
      ),
    ),
    payload: jsonEncode(message.data),
  );
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

/// Tapping a push the OS showed opens what it is about. Two entry points,
/// because firebase_messaging reports them differently: the app was KILLED and
/// the tap launched it (getInitialMessage — resolves once, at startup) or it
/// was in the background (onMessageOpenedApp). Neither was handled before, so
/// a tap only brought the app to whatever screen it was last on and left the
/// user to hunt for the chat — the single most common way people open a
/// messenger. Registered from main() with the app-lifetime container, like
/// the outbox. (A tap on a notification the app posted itself while open
/// arrives through the local plugin instead — setUpForegroundNotifications.)
void listenNotificationTaps(ProviderContainer container) {
  FirebaseMessaging.instance.getInitialMessage().then((message) {
    if (message != null) _openFromNotificationData(container, message.data);
  });
  FirebaseMessaging.onMessageOpenedApp.listen(
    (message) => _openFromNotificationData(container, message.data),
  );
}

// The local plugin hands back the JSON-encoded FCM data the notification was
// posted with (see _showForegroundNotification), so both tap paths converge.
void _openFromPayload(ProviderContainer container, String? payload) {
  if (payload == null || payload.isEmpty) return;
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    _openFromNotificationData(container, data);
  } catch (e) {
    debugPrint('notification tap: unreadable payload: $e');
  }
}

Future<void> _openFromNotificationData(
  ProviderContainer container,
  Map<String, dynamic> data,
) async {
  final kind = _PushKind(data);
  if (kind.chatId == null && !kind.isBroadcast) return;
  debugPrint(
    'notification tap: opening ${kind.chatId != null ? "chat ${kind.chatId}" : "inbox"}',
  );
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
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  final chatId = kind.chatId;
  if (chatId != null) {
    if (chatId == _activeChatId) return; // already looking at it
    GoRouter.of(context).push('/chat/$chatId');
  } else {
    GoRouter.of(context).push('/settings/notifications');
  }
}

class NotificationService {
  NotificationService(this._messaging, this._api);

  final FirebaseMessaging _messaging;
  final ApiClient _api;

  /// Requests permission, fetches the FCM token, and registers it with the
  /// API (POST /users/me/fcm-tokens — UNIQUE(token) upsert; see
  /// docs/07_MIGRATION.md Phase 7). Called from SeMayApp once auth resolves.
  /// The one permission prompt covers the app's own foreground notifications
  /// too: Android 13+'s POST_NOTIFICATIONS gates every notification alike.
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
