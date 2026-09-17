// Drives the REAL setUpForegroundNotifications / _showForegroundNotification
// path headlessly: RemoteMessages are fed into FirebaseMessagingPlatform.
// onMessage — the StreamController FirebaseMessaging.onMessage is backed by —
// and the only things mocked are flutter_local_notifications' method channel
// (so the assertions are on the exact arguments the Android plugin would post)
// and the app's own iOS channel (so the active-chat mirror is observable).
// Nothing else is stubbed: _markMessageDelivered's secure-storage read throws
// MissingPluginException, which it catches.
//
// A CHAT message arriving while the app is OPEN no longer posts a system
// notification on either platform: it raises the in-app banner instead
// (chatBannerProvider → ChatBannerHost, mounted above the navigator), which is
// what Instagram does and what the owner asked for. Posting both put two
// notices on screen for one message. Announcements and order notices are
// unchanged. The suppression rule is untouched and still shared:
// shouldPresentPush decides the banner exactly as it decided the notification.

import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/features/chat/in_app_banner.dart';
import 'package:semay/services/notification_service.dart';

const _localChannel = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);
const _iosChannel = MethodChannel('com.semay.semay/notifications');

RemoteMessage _chatPush({required String chatId, required String messageId}) =>
    RemoteMessage.fromMap({
      'messageId': messageId,
      'data': {
        'type': 'chat_message',
        'chatId': chatId,
        'messageId': '1',
        'senderRole': 'admin',
      },
      'notification': {'title': 'Store', 'body': 'hello'},
    });

RemoteMessage _broadcastPush({required String messageId}) =>
    RemoteMessage.fromMap({
      'messageId': messageId,
      'data': {'type': 'broadcast'},
      'notification': {'title': 'SeMay', 'body': 'announcement'},
    });

// orders/service.ts sends title/body only — no data at all.
RemoteMessage _orderPush({required String messageId}) => RemoteMessage.fromMap({
  'messageId': messageId,
  'data': <String, dynamic>{},
  'notification': {'title': 'New order', 'body': 'Aman placed an order (2)'},
});

/// Feeds a message into the same stream FirebaseMessaging.onMessage is backed
/// by and lets the async listener (and the plugin's show()) run.
Future<void> _deliver(RemoteMessage m) async {
  FirebaseMessagingPlatform.onMessage.add(m);
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<dynamic, dynamic> _android(Map<dynamic, dynamic> show) =>
    show['platformSpecifics'] as Map<dynamic, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The app-lifetime container setUpForegroundNotifications is handed in
  // main(); the in-app banner is written into it, so the test reads it back
  // from the same place ChatBannerHost watches.
  final container = ProviderContainer();

  final shows = <Map<dynamic, dynamic>>[];
  final localCalls = <String>[];
  final iosActiveChats = <String?>[];
  final iosDismissed = <String?>[];
  var broadcasts = 0;
  /// When set, the mocked plugin rejects every show() the way the real Android
  /// plugin does when it refuses to post at all (a bad small icon,
  /// POST_NOTIFICATIONS revoked mid-session).
  var rejectShow = false;

  // setUpForegroundNotifications subscribes to a static broadcast stream, so
  // it runs once for the whole file — a second call would post every push
  // twice.
  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // What the generated Dart plugin registrant does at app start.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_localChannel, (call) async {
          localCalls.add(call.method);
          switch (call.method) {
            case 'initialize':
              return true;
            case 'show':
              final args = Map<dynamic, dynamic>.from(call.arguments as Map);
              shows.add(args);
              if (rejectShow) {
                throw PlatformException(
                  code: 'invalid_icon',
                  message: 'The resource could not be resolved',
                );
              }
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_iosChannel, (call) async {
          switch (call.method) {
            case 'setActiveChat':
              iosActiveChats.add(call.arguments as String?);
            case 'dismissChat':
              iosDismissed.add(call.arguments as String?);
            default:
              fail('unexpected iOS channel method ${call.method}');
          }
          return null;
        });
    await setUpForegroundNotifications(container, onBroadcast: () => broadcasts++);
  });

  setUp(() {
    shows.clear();
    localCalls.clear();
    iosActiveChats.clear();
    iosDismissed.clear();
    rejectShow = false;
    setLocallyActiveChatId(null);
    container.read(chatBannerProvider.notifier).dismiss();
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
    container.dispose();
  });

  group('foreground chat messages raise the in-app banner', () {
    test('inside chat A, a message for A shows nothing at all', () async {
      setLocallyActiveChatId('chatA');
      await _deliver(_chatPush(chatId: 'chatA', messageId: 'm1'));
      expect(shows, isEmpty);
      expect(localCalls, isEmpty);
      expect(container.read(chatBannerProvider), isNull);
    });

    test(
      'inside chat A, a message for B banners in-app and posts no notification',
      () async {
        setLocallyActiveChatId('chatA');
        await _deliver(_chatPush(chatId: 'chatB', messageId: 'm2'));
        expect(shows, isEmpty, reason: 'the banner replaces the system notice');
        final banner = container.read(chatBannerProvider);
        expect(banner, isNotNull);
        expect(banner!.chatId, 'chatB');
        // Sender name and preview come straight off the push the server
        // already composes — the banner needs no extra fetch to say something.
        expect(banner.title, 'Store');
        expect(banner.body, 'hello');
      },
    );

    test(
      'on the chat list (no thread open), a message banners in-app',
      () async {
        await _deliver(_chatPush(chatId: 'chatA', messageId: 'm3'));
        expect(shows, isEmpty);
        expect(container.read(chatBannerProvider)?.chatId, 'chatA');
      },
    );

    // Two messages in a row must not leave the first banner frozen on screen:
    // each show() carries a new id, which restarts the animation and the
    // auto-dismiss timer.
    test('a second message replaces the first banner', () async {
      await _deliver(_chatPush(chatId: 'chatA', messageId: 'm3a'));
      final first = container.read(chatBannerProvider)!;
      await _deliver(_chatPush(chatId: 'chatB', messageId: 'm3b'));
      final second = container.read(chatBannerProvider)!;
      expect(second.chatId, 'chatB');
      expect(second.id, isNot(first.id));
      // The stale timer for the first one may no longer take the second down.
      container.read(chatBannerProvider.notifier).dismiss(onlyIfId: first.id);
      expect(container.read(chatBannerProvider), isNotNull);
      container.read(chatBannerProvider.notifier).dismiss(onlyIfId: second.id);
      expect(container.read(chatBannerProvider), isNull);
    });
  });

  group('Android foreground', () {
    test(
      'a broadcast inside chat A posts on announcements with no sound override',
      () async {
        setLocallyActiveChatId('chatA');
        final before = broadcasts;
        await _deliver(_broadcastPush(messageId: 'm4'));
        expect(shows, hasLength(1));
        final android = _android(shows.single);
        expect(shows.single['id'], 0);
        expect(android['channelId'], 'announcements');
        expect(android['channelName'], 'Bildirişler');
        expect(android['sound'], isNull);
        expect(android['tag'], 'broadcast');
        expect(broadcasts, before + 1);
      },
    );

    test(
      'an order notice posts on orders with no sound override and its own id',
      () async {
        setLocallyActiveChatId('chatA');
        await _deliver(_orderPush(messageId: 'o1'));
        expect(shows, hasLength(1));
        final android = _android(shows.single);
        expect(shows.single['id'], 'o1'.hashCode);
        expect(android['channelId'], 'orders');
        expect(android['channelName'], 'Sargytlar');
        expect(android['sound'], isNull);
        expect(android['tag'], isNull);
      },
    );

    // The Android plugin refuses the whole show() rather than degrading (a
    // bad small icon, POST_NOTIFICATIONS revoked mid-session), and the
    // returned Future is deliberately not awaited by the onMessage listener,
    // so an unguarded throw became an unhandled async error — which fails this
    // test if the catch in _showForegroundNotification is ever removed. There
    // is no retry any more: nothing is overridden on the post (no sound since
    // the custom one was dropped), so a second identical attempt could only
    // fail the same way.
    test('a rejected show() is swallowed, not retried', () async {
      rejectShow = true;
      await _deliver(_broadcastPush(messageId: 'm5'));
      expect(shows, hasLength(1));
      final attempt = _android(shows.single);
      expect(attempt['sound'], isNull);
      expect(attempt['channelId'], 'announcements');
      expect(attempt['tag'], 'broadcast');
      expect(shows.single['id'], 0);
      expect(shows.single['body'], 'announcement');
    });

    // Opening a thread clears its notification, on the plugin identity FCM's
    // own Android SDK uses for a background delivery (tag = chat id, id 0).
    test('opening a thread cancels that chat\'s notification', () async {
      await dismissChatNotification('chatA');
      expect(localCalls, ['cancel']);
      expect(iosDismissed, isEmpty);
    });
  });

  test(
    'iOS: the app posts no local notification and mirrors the active chat natively',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(
        () => debugDefaultTargetPlatformOverride = TargetPlatform.android,
      );

      setLocallyActiveChatId('chatA');
      await _deliver(_chatPush(chatId: 'chatA', messageId: 'i1'));
      await _deliver(_chatPush(chatId: 'chatB', messageId: 'i2'));
      await _deliver(_broadcastPush(messageId: 'i3'));
      setLocallyActiveChatId(null);
      await _deliver(_chatPush(chatId: 'chatA', messageId: 'i4'));

      // Presentation is the OS's (AppDelegate.swift), never a local copy.
      expect(shows, isEmpty);
      expect(localCalls, isEmpty);
      // Enter and leave both reached the native side, in order.
      expect(iosActiveChats, ['chatA', null]);
      // The in-app banner is not platform-specific — the same Dart handler
      // raises it on iOS, where AppDelegate.swift answers a foreground chat
      // push with badge + sound and no OS banner so there is only ever one.
      // The last push (chat A, after the thread was left) is the one showing.
      expect(container.read(chatBannerProvider)?.chatId, 'chatA');
    },
  );

  // Dismiss-on-open used to be Android-only, so on iOS a banner for a chat the
  // user had just read sat in Notification Center until they swiped it away —
  // a platform split the owner sees on the phone. iOS has no local-notification
  // plugin here, so it goes over the app's own channel to AppDelegate.swift,
  // which removes the delivered notifications whose chatId matches.
  test('iOS: opening a thread removes its delivered notifications', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(
      () => debugDefaultTargetPlatformOverride = TargetPlatform.android,
    );

    await dismissChatNotification('chatA');
    expect(iosDismissed, ['chatA']);
    // Never the Android plugin: it is not even initialized on iOS.
    expect(localCalls, isEmpty);
  });
}
