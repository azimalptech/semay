// The chat attachment's progress, on the real ChatThreadScreen.
//
// Chat is deliberately unlike the composers: the upload runs in the background
// outbox with retry, so there is no modal and nothing is disabled — the user
// keeps typing while the photo goes up. What it owed the user was a NUMBER:
// the queued bubble used to spin an indeterminate ring that looked identical
// at 2 % and at 98 %, and identical to a stalled upload.

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
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/chat/chat_thread_screen.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/auth_service.dart';

import '../support/fake_realtime.dart';

const _chatId = 'u1_s1';
const _clientKey = 'queued-key-1';
const _s = S(false);
const _tick = Duration(milliseconds: 10);

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async =>
      path == '/chats/$_chatId/messages' ? {'messages': const <dynamic>[]} : {};

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async => {};
}

class _FakeSession extends SessionController {
  @override
  Future<SessionClaims?> build() async =>
      const SessionClaims(uid: 'u1', role: 'user', storeIds: [], claimsVersion: 1);
}

/// One queued video attachment, exactly as ChatService.sendMediaMessage leaves
/// it: a local file, no mediaUrl yet, keyed by clientKey.
OutboxItem _queuedAttachment() => OutboxItem(
  id: _clientKey,
  kind: OutboxKind.message,
  payload: const {
    'chatId': _chatId,
    'text': '',
    'senderRole': 'user',
    'mediaType': 'video',
    'localMediaPath': '/tmp/does-not-need-to-exist.mp4',
  },
  createdAt: DateTime.now().millisecondsSinceEpoch,
  attempts: 0,
);

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  required Map<String, double> progress,
}) async {
  stubConnectivity();
  final connector = FakeConnector();
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(_s),
      sessionControllerProvider.overrideWith(_FakeSession.new),
      secureSessionStoreProvider.overrideWithValue(
        MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
      ),
      appRoleProvider.overrideWith((ref) async => AppRole.user),
      storeIdsProvider.overrideWith((ref) async => const <String>[]),
      apiClientProvider.overrideWithValue(_FakeApi()),
      chatCacheProvider.overrideWithValue(MemChatCache()),
      realtimeSocketConnectorProvider.overrideWithValue(connector.call),
      chatDocProvider.overrideWith(
        (ref, id) => Stream.value({
          'id': id,
          'userId': 'u1',
          'storeId': 's1',
          'unreadByUser': 0,
          'unreadByAdmin': 0,
        }),
      ),
      storeDocProvider.overrideWith(
        (ref, id) => Stream.value({'id': id, 'name': 'Shop', 'avatarUrl': '', 'phone': ''}),
      ),
      userDocProvider.overrideWith((ref, id) async => null),
      pendingMessagesProvider.overrideWith(
        (ref, id) => Stream.value([_queuedAttachment()]),
      ),
      // What the outbox publishes while the bytes are on the wire.
      outboxUploadProgressProvider.overrideWith((ref) => Stream.value(progress)),
    ],
  );
  await container.read(sessionControllerProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ChatThreadScreen(chatId: _chatId)),
    ),
  );
  await tester.pump(_tick);
  return container;
}

/// The ring drawn over the queued attachment thumbnail (the composer's own
/// widgets are not progress indicators, so this is unambiguous).
CircularProgressIndicator _ring(WidgetTester tester) =>
    tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );

Future<void> _unmount(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

void main() {
  testWidgets('a queued attachment shows the real percentage, determinate', (
    tester,
  ) async {
    final container = await _mount(tester, progress: const {_clientKey: 0.45});

    expect(_ring(tester).value, 0.45, reason: 'determinate, not a spinner');
    expect(find.text('45%'), findsOneWidget);

    // The composer is NOT blocked: this upload is a background job, not a
    // modal the user waits on.
    final input = tester.widget<TextField>(find.byType(TextField).first);
    expect(input.enabled, isNot(false));

    await _unmount(tester, container);
  });

  testWidgets('the percentage follows the outbox as bytes go out', (tester) async {
    for (final fraction in [0.0, 0.25, 0.99]) {
      final container = await _mount(tester, progress: {_clientKey: fraction});
      expect(_ring(tester).value, fraction);
      expect(find.text('${(fraction * 100).floor()}%'), findsOneWidget);
      await _unmount(tester, container);
    }
  });

  testWidgets('nothing on the wire: the ring stays, indeterminate, with no number', (
    tester,
  ) async {
    // Queued but not yet started (or uploaded and waiting on the POST) — the
    // message is still on its way, so the ring stays; there is simply no
    // honest number to show.
    final container = await _mount(tester, progress: const {});

    expect(_ring(tester).value, isNull);
    expect(find.textContaining('%'), findsNothing);

    await _unmount(tester, container);
  });

  testWidgets('another chat\'s upload does not bleed into this bubble', (
    tester,
  ) async {
    final container = await _mount(tester, progress: const {'someone-elses-key': 0.8});

    expect(_ring(tester).value, isNull);
    expect(find.text('80%'), findsNothing);

    await _unmount(tester, container);
  });
}
