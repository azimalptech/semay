import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/firebase_options.dart';
import '../features/chat/in_app_banner.dart';
import 'auth_service.dart';

// Web push needs a VAPID key, which is per-project and can't be derived from
// firebase_options.dart. Web is not a shipping target (the product is Android +
// iOS), so rather than calling getToken with a placeholder that always throws,
// registration is skipped on web unless a real key is supplied at build time:
//   flutter build web --dart-define=FCM_VAPID_KEY=...
const _webVapidKey = String.fromEnvironment('FCM_VAPID_KEY');

// Android notification channels, created at IMPORTANCE_HIGH by
// SemayApplication.kt on every process start (ids must match there and on the
// server: CHAT_PUSH_CHANNEL in chats/service.ts, BROADCAST_PUSH_CHANNEL in
// notifications/service.ts, ORDER_PUSH_CHANNEL in orders/service.ts). A
// backgrounded app's push lands on them via FCM; a foreground one is posted
// here on the same channel, so the user's per-channel settings apply to both.
// No channel carries a sound of its own: all three play the phone's default
// notification sound, which is what the owner asked for. Nothing here passes a
// sound override, so on API 26+ the channel's sound (the system default)
// applies, and below 26 the plugin falls back to the same default.
//
// The names below are a fallback the user should never see: the plugin only
// creates a channel when one with that id does not exist, and the Application
// has already created all three by the time any Dart runs. They are the
// Turkmen strings from res/values/strings.xml all the same — the product
// ships tk/ru only (core/l10n.dart), so an English channel name has no
// business being reachable at all.
const _chatChannelId = 'chat_messages';
const _chatChannelName = 'Habarlar';
const _announcementsChannelId = 'announcements';
const _announcementsChannelName = 'Bildirişler';
const _ordersChannelId = 'orders';
const _ordersChannelName = 'Sargytlar';

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

/// THE rule for a chat push, the same on both platforms: a chat push is
/// silent ONLY when its chatId equals the thread on screen with the app
/// resumed; everything else — the chat list, the inbox, any other tab, a
/// message for chat B while in chat A, a backgrounded or killed app — shows
/// normally, with the phone's default notification sound; broadcasts (no
/// chatId) are never suppressed. Android
/// applies it in _showForegroundNotification; iOS applies the same `==` in
/// AppDelegate.swift's willPresent override, fed by the mirror below, because
/// there the OS presents the push and Dart is never asked.
bool shouldPresentPush({
  required String? chatId,
  required String? activeChatId,
}) => chatId == null || chatId != activeChatId;

/// What [setLocallyActiveChatId] last stored, for the one caller that has to
/// know whether the thread on screen is still ITS thread: ChatThreadScreen's
/// dispose only clears the flag when it still names that screen's chat.
/// Thread B stacked over thread A is disposed AFTER A's didPopNext has
/// already claimed the flag back (a pop's route callbacks run when the pop
/// starts, the disposal when its animation ends), so an unconditional clear
/// there left A on screen with the flag at null — and every further message
/// for the chat the user was staring at rang.
String? get locallyActiveChatId => _activeChatId;

/// Set by ChatThreadScreen when it is the thread on screen (the id) and
/// cleared when it is not — left, covered by another route, or the app
/// backgrounded — so "on screen with the app resumed" is exactly when this
/// holds a value.
void setLocallyActiveChatId(String? chatId) {
  _activeChatId = chatId;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    unawaited(_mirrorActiveChatToIos(chatId));
  }
}

// iOS decides foreground presentation natively (see
// _postsForegroundNotifications), so the active chat is mirrored to
// AppDelegate.swift, which keeps its own copy for the willPresent override.
// Fire-and-forget: the screen must not wait on it, and a failure (a native
// build without the handler) only means that iOS user hears the sound inside
// the open thread — the behaviour before the mirror existed, never a crash.
const _iosNotificationsChannel = MethodChannel('com.semay.semay/notifications');

Future<void> _mirrorActiveChatToIos(String? chatId) async {
  try {
    await _iosNotificationsChannel.invokeMethod<void>('setActiveChat', chatId);
  } catch (e) {
    debugPrint('setActiveChat mirror failed: $e');
  }
}

// Anchors notification-tap navigation outside any single screen's widget tree
// — router.dart wires this into MaterialApp.router's navigatorKey, the same
// "global key set up before runApp, used by code with no BuildContext of its
// own" pattern firebaseMessagingBackgroundHandler already relies on for
// Firebase itself. A NavigatorState's context sits above every route, which is
// what lets GoRouter.of(context) resolve from a push handler.
final rootNavigatorKey = GlobalKey<NavigatorState>();

// What a push is about, read off its data payload. The server sets `type`
// ('chat_message' with a chatId, or 'broadcast'); anything else — an order
// notice — has nowhere to route and is posted on the orders channel.
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
    // A CHAT message while the app is open is announced by the in-app banner
    // (features/chat/in_app_banner.dart), not by a system notification — the
    // way Instagram does it, and the reason _showForegroundNotification now
    // returns early for one. Everything else (announcements, order notices)
    // still goes to the shade on Android / to the OS on iOS.
    if (kind.chatId != null) {
      _showInAppBanner(container, message, kind.chatId!);
      return;
    }
    _showForegroundNotification(message, kind);
  });
}

/// The in-app banner for a foreground chat push. Suppression is
/// [shouldPresentPush] — the one rule, shared with the OS notification path
/// and with AppDelegate.swift: a message for the thread already on screen
/// shows nothing at all.
void _showInAppBanner(
  ProviderContainer container,
  RemoteMessage message,
  String chatId,
) {
  if (!shouldPresentPush(chatId: chatId, activeChatId: _activeChatId)) {
    debugPrint('foreground push: suppressed, chat $chatId is on screen');
    return;
  }
  final title = message.notification?.title ?? '';
  final body = message.notification?.body ?? '';
  if (title.isEmpty && body.isEmpty) return;
  container.read(chatBannerProvider.notifier).show(
    chatId: chatId,
    title: title,
    body: body,
  );
}

// Android's system notification for a foreground push — announcements and
// order notices only now: a chat message arriving while the app is open is
// the in-app banner's job (see the onMessage listener above), and posting both
// put two notices on screen for one message.
//
// The rest is unchanged, and still describes chat because a chat push posted
// from the BACKGROUND (by FCM's own SDK) uses exactly this identity, which is
// what dismissChatNotification below cancels.
//
// Android's system notification for a foreground push — the same channel, tag
// and (id 0) identity FCM's own Android SDK uses for a background delivery, so
// a chat that already has a notification in the shade gets it REPLACED rather
// than a second one stacked next to it. A push with no collapse identity (an
// order notice: no chatId, no type) gets no tag and its own id instead, so it
// stacks the way FCM's background delivery does — with tag 'broadcast' it
// would silently overwrite a pending announcement, and vice versa. Skipped
// entirely when shouldPresentPush says the recipient is already looking
// straight at this exact chat (the server sends the push regardless, by
// design; see _activeChatId).
Future<void> _showForegroundNotification(
  RemoteMessage message,
  _PushKind kind,
) async {
  if (!_postsForegroundNotifications) return;
  if (!shouldPresentPush(chatId: kind.chatId, activeChatId: _activeChatId)) {
    debugPrint('foreground push: suppressed, chat ${kind.chatId} is on screen');
    return;
  }
  final title = message.notification?.title ?? '';
  final body = message.notification?.body ?? '';
  if (title.isEmpty && body.isEmpty) return;

  final isChat = kind.chatId != null;
  final channelId = isChat
      ? _chatChannelId
      : kind.isBroadcast
      ? _announcementsChannelId
      : _ordersChannelId;
  final channelName = isChat
      ? _chatChannelName
      : kind.isBroadcast
      ? _announcementsChannelName
      : _ordersChannelName;
  final tag = kind.chatId ?? (kind.isBroadcast ? 'broadcast' : null);
  // messageId is set by FCM's Android SDK on every delivery; its String
  // hashCode fits the 32-bit id the plugin requires.
  final id = tag == null ? message.messageId.hashCode : 0;
  final payload = jsonEncode(message.data);

  // No `sound:` anywhere: every channel plays the phone's default
  // notification sound, so there is nothing to override. Leaving it unset is
  // also what keeps the plugin from ever raising `invalid_sound` — it only
  // validates a raw resource that was actually named.
  //
  // The plugin THROWS rather than degrading (a bad small icon, or
  // POST_NOTIFICATIONS revoked mid-session), and this Future is deliberately
  // not awaited by the onMessage listener, so an unguarded throw became an
  // unhandled async error. Caught here: a failed post must cost the banner,
  // never the app.
  try {
    await _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          // Matches the channel SemayApplication.kt created; the plugin would
          // otherwise create a default-importance one under the same id on a
          // device where it somehow has not run yet, and a channel's
          // importance is fixed at creation.
          importance: Importance.high,
          priority: Priority.high,
          tag: tag,
        ),
      ),
      payload: payload,
    );
  } catch (e) {
    debugPrint('foreground notification failed: $e');
  }
}

/// Clears the shade entry for [chatId] once its thread is on screen — the
/// one FCM's SDK posted for a background delivery or the one posted here.
/// A notification for a conversation the user is reading right now is stale
/// the moment they open it; WhatsApp and Instagram both clear it, and leaving
/// it makes the user swipe away a notice for a message they have already read.
///
/// Both platforms, by different routes, because the identity differs:
/// Android's is the plugin's (tag = chat id, id 0 — the same identity FCM's
/// own Android SDK uses, which _showForegroundNotification mirrors); iOS has
/// no local-notification plugin here (the OS presents foreground pushes
/// itself), so AppDelegate.swift matches delivered notifications on the
/// push's `chatId` and removes them.
///
/// The launcher NUMBER is a separate thing: on Android the count is derived
/// from the notifications themselves, so this call is what drops it; on iOS
/// the server corrects the icon number with a badge-only push after the read
/// receipt (chats/service.ts syncLauncherBadges).
Future<void> dismissChatNotification(String chatId) async {
  if (kIsWeb) return;
  try {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _iosNotificationsChannel.invokeMethod<void>('dismissChat', chatId);
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _localNotifications.cancel(id: 0, tag: chatId);
  } catch (e) {
    // Never fatal: a native build without the handler (or a revoked
    // permission) only means one stale notice stays in the shade.
    debugPrint('dismissChatNotification failed: $e');
  }
}

// Marks the message the push refers to as "delivered" — the recipient's
// device actually received it, independent of whether they ever open the
// thread. Nothing in the UI shows this any more (Instagram has no delivered
// step — see chat_thread_screen.dart's MessageStatusLine); it is still
// recorded because unread counters, the Chat tab badge and the launcher badge
// are all built on it. The server's sendChatPush attaches chatId/messageId
// as the FCM data payload specifically so this has something to write to;
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
