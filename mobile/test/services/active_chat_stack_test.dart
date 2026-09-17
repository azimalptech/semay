// The suppression flag's lifecycle, against the REAL ChatThreadScreen and the
// REAL router-wide observer (core/shell_tab.dart's shellRouteObserver).
//
// notification_service.dart states the rule once: a chat push is silent ONLY
// when its chatId equals the thread ON SCREEN with the app resumed. "On
// screen" is not "mounted", and getting that wrong is what a reviewer found:
//
//  * a route pushed OVER the thread (the store profile, a shared post, the
//    attachment viewer) leaves it mounted, so a message for it stayed silent
//    while the user was looking at something else;
//  * worse, tapping a push for chat B from inside chat A stacks B on A, and
//    B's dispose used to clear the flag unconditionally — A was then the
//    visible route with the flag at null, so every later message for the chat
//    the user was staring at rang.
//
// Both are pinned here, on the flag notification_service.dart actually reads
// (locallyActiveChatId) rather than on a copy.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/chat_cache.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/session.dart';
import 'package:semay/core/shell_tab.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/chat/chat_thread_screen.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/auth_service.dart';
import 'package:semay/services/chat_service.dart';
import 'package:semay/services/notification_service.dart';

import '../support/fake_realtime.dart';

const _chatA = 'u1_s1';
const _chatB = 'u1_s2';
const _s = S(false);

/// Route transitions are animated; the staleness Timer in the thread
/// re-schedules a frame every second, so pumpAndSettle would never settle.
const _transition = Duration(milliseconds: 500);

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  /// Every value PATCH /users/me carried for `activeChatId`, in order.
  final activeChats = <String?>[];

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    if (path.endsWith('/messages')) return {'messages': <Map<String, dynamic>>[]};
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    if (path == '/users/me' && body is Map && body.containsKey('activeChatId')) {
      activeChats.add(body['activeChatId'] as String?);
    }
    return {};
  }
}

class _FakeSession extends SessionController {
  @override
  Future<SessionClaims?> build() async =>
      const SessionClaims(uid: 'u1', role: 'user', storeIds: [], claimsVersion: 1);
}

void main() {
  late _FakeApi api;
  late FakeConnector connector;
  late ProviderContainer container;
  final navKey = GlobalKey<NavigatorState>();

  Future<void> mountThreadA(WidgetTester tester) async {
    setLocallyActiveChatId(null);
    stubConnectivity();
    api = _FakeApi();
    connector = FakeConnector();
    container = ProviderContainer(
      overrides: [
        l10nProvider.overrideWithValue(_s),
        sessionControllerProvider.overrideWith(_FakeSession.new),
        secureSessionStoreProvider.overrideWithValue(
          MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
        ),
        appRoleProvider.overrideWith((ref) async => AppRole.user),
        storeIdsProvider.overrideWith((ref) async => const <String>[]),
        apiClientProvider.overrideWithValue(api),
        chatCacheProvider.overrideWithValue(MemChatCache()),
        realtimeSocketConnectorProvider.overrideWithValue(connector.call),
        chatDocProvider.overrideWith(
          (ref, id) => Stream.value({
            'id': id,
            'userId': 'u1',
            'storeId': id == _chatA ? 's1' : 's2',
            'unreadByUser': 0,
            'unreadByAdmin': 0,
          }),
        ),
        storeDocProvider.overrideWith(
          (ref, id) => Stream.value({'id': id, 'name': 'Shop $id', 'avatarUrl': '', 'phone': ''}),
        ),
        userDocProvider.overrideWith((ref, id) async => null),
        pendingMessagesProvider.overrideWith((ref, id) => Stream.value(const <OutboxItem>[])),
      ],
    );
    await container.read(sessionControllerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navKey,
          // Exactly what router.dart registers on the GoRouter, so the
          // thread hears the same didPushNext/didPopNext it hears in the app.
          navigatorObservers: [shellRouteObserver],
          home: const ChatThreadScreen(chatId: _chatA),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
    container.dispose();
  }

  testWidgets('entering chat A claims the flag', (tester) async {
    await mountThreadA(tester);
    // The flag the push handler reads is set synchronously…
    expect(locallyActiveChatId, _chatA);
    // …while the server mirror — diagnostic-only, read by nothing — is
    // debounced, so a transition costs no round trip on its own.
    expect(api.activeChats, isEmpty);
    await tester.pump(ChatService.activeChatMirrorDelay);
    expect(api.activeChats, [_chatA]);
    await unmount(tester);
    expect(locallyActiveChatId, isNull);
  });

  // The reported blocker: tap a push for chat B from inside chat A (
  // notification_service.dart pushes, it does not replace), then press back.
  testWidgets('A -> push B -> pop B leaves the flag on A, the thread on screen', (
    tester,
  ) async {
    await mountThreadA(tester);
    expect(locallyActiveChatId, _chatA);

    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const ChatThreadScreen(chatId: _chatB)),
    );
    await tester.pump();
    await tester.pump(_transition);
    expect(locallyActiveChatId, _chatB, reason: 'B is the thread on screen now');

    navKey.currentState!.pop();
    await tester.pump();
    await tester.pump(_transition);
    // B's State is disposed at the END of the pop animation, after A's
    // didPopNext already reclaimed the flag; an unconditional clear there
    // left A visible with the flag at null and A then rang.
    expect(locallyActiveChatId, _chatA, reason: 'A is on screen again');
    // The server-side hint follows the same trail — A, null (A releasing on
    // didPushNext), B, A — but only the value it comes to rest on is ever
    // sent. Four `PATCH /users/me` round trips for a field the server
    // documents as diagnostic-only and reads nowhere, collapsed into one.
    expect(api.activeChats, isEmpty);
    await tester.pump(ChatService.activeChatMirrorDelay);
    expect(api.activeChats, [_chatA]);

    await unmount(tester);
    expect(locallyActiveChatId, isNull);
  });

  // The other half of "on screen": the thread's own pushes — the store
  // profile, a shared post, the full-screen attachment viewer.
  testWidgets('a route pushed over the thread releases the flag, popping it takes it back', (
    tester,
  ) async {
    await mountThreadA(tester);
    expect(locallyActiveChatId, _chatA);

    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('store profile'))),
    );
    await tester.pump();
    await tester.pump(_transition);
    expect(locallyActiveChatId, isNull,
        reason: 'a message for A must ring while the user is on another screen');

    navKey.currentState!.pop();
    await tester.pump();
    await tester.pump(_transition);
    expect(locallyActiveChatId, _chatA);

    await unmount(tester);
  });

  // A dialog or bottom sheet is a PopupRoute, not a PageRoute: the thread is
  // still what the user is looking at behind it.
  testWidgets('a popup over the thread does not release the flag', (tester) async {
    await mountThreadA(tester);
    unawaited(
      showDialog<void>(
        context: navKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('sure?')),
      ),
    );
    await tester.pump();
    await tester.pump(_transition);
    expect(locallyActiveChatId, _chatA);

    navKey.currentState!.pop();
    await tester.pump();
    await tester.pump(_transition);
    expect(locallyActiveChatId, _chatA);

    await unmount(tester);
  });
}
