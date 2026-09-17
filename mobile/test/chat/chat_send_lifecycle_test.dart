// The send lifecycle on the real ChatThreadScreen, exactly as the owner
// described Instagram: a message appears at once but faded, with a clock and
// "Sending…"; it becomes "Sent" once the server has it; a message that could
// not be sent shows a red exclamation mark and "Not sent. Tap to try again",
// and tapping it offers Retry or Delete rather than silently re-sending.
//
// Plus the typing indicator's missing half: their picture beside the animated
// dots at the bottom of the conversation.

import 'package:connectivity_plus/connectivity_plus.dart';
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
import 'package:semay/core/theme.dart';
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

/// Records what the failed-message sheet asks the queue to do. Nothing else is
/// stubbed out — `retry` and `discard` are the entire contract between the
/// sheet and the outbox.
class _FakeOutbox extends OutboxService {
  _FakeOutbox()
    : super(
        _FakeApi(),
        Connectivity(),
        hasSession: () => true,
        uploader:
            ({
              required folder,
              required bytes,
              required fileExt,
              required contentType,
              onProgress,
            }) async => '',
      );

  final retried = <String>[];
  final discarded = <String>[];

  @override
  Future<void> retry(String id) async => retried.add(id);

  @override
  Future<void> discard(String id) async => discarded.add(id);
}

/// One text message sitting in the outbox. [attempts] at or past
/// outboxFailedAfterAttempts is what turns it red (OutboxItem.looksFailed).
OutboxItem _queued({required int attempts}) => OutboxItem(
  id: _clientKey,
  kind: OutboxKind.message,
  payload: const {'chatId': _chatId, 'text': 'salam', 'senderRole': 'user'},
  createdAt: DateTime.now().millisecondsSinceEpoch,
  attempts: attempts,
);

class _Harness {
  _Harness({required this.pending, this.typingAdminAt});

  final List<OutboxItem> pending;
  final DateTime? typingAdminAt;

  final outbox = _FakeOutbox();
  late final ProviderContainer container;

  Future<void> mount(WidgetTester tester) async {
    stubConnectivity();
    final connector = FakeConnector();
    container = ProviderContainer(
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
        outboxServiceProvider.overrideWithValue(outbox),
        chatDocProvider.overrideWith(
          (ref, id) => Stream.value({
            'id': id,
            'userId': 'u1',
            'storeId': 's1',
            'unreadByUser': 0,
            'unreadByAdmin': 0,
            if (typingAdminAt != null)
              'typingAdminAt': typingAdminAt!.toUtc().toIso8601String(),
          }),
        ),
        storeDocProvider.overrideWith(
          (ref, id) => Stream.value({
            'id': id,
            'name': 'Shop',
            'avatarUrl': '',
            'phone': '',
          }),
        ),
        userDocProvider.overrideWith((ref, id) async => null),
        pendingMessagesProvider.overrideWith((ref, id) => Stream.value(pending)),
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
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }
}

/// The opacity the bubble is wrapped in, or 1 when it isn't wrapped at all.
double _bubbleOpacity(WidgetTester tester) {
  final wrappers = find.ancestor(
    of: find.text('salam'),
    matching: find.byType(Opacity),
  );
  if (wrappers.evaluate().isEmpty) return 1;
  return tester.widget<Opacity>(wrappers.first).opacity;
}

void main() {
  testWidgets('sending: the bubble is there at once, faded, with a clock and "Sending…"', (
    tester,
  ) async {
    final h = _Harness(pending: [_queued(attempts: 0)]);
    await h.mount(tester);

    expect(find.text('salam'), findsOneWidget, reason: 'shown before it is sent');
    expect(_bubbleOpacity(tester), lessThan(1.0));
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.text(_s.sendingStatus), findsOneWidget);
    // Not sent, not seen, and no red mark yet.
    expect(find.textContaining(_s.sentAgo('').trim()), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.text(_s.notSentTapToRetry), findsNothing);

    await h.unmount(tester);
  });

  testWidgets('not sent: a red exclamation mark, the retry label, and no status line', (
    tester,
  ) async {
    final h = _Harness(pending: [_queued(attempts: outboxFailedAfterAttempts)]);
    await h.mount(tester);

    final mark = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(mark.color, AppColors.error);
    expect(find.text(_s.notSentTapToRetry), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsNothing);
    // The red line speaks for the message; "Sending…" alongside it would be a
    // lie and "Sent" a worse one.
    expect(find.byType(MessageStatusLine), findsNothing);

    await h.unmount(tester);
  });

  testWidgets('tapping a failed message offers Retry and Delete, and does neither by itself', (
    tester,
  ) async {
    final h = _Harness(pending: [_queued(attempts: outboxFailedAfterAttempts)]);
    await h.mount(tester);

    await tester.tap(find.text('salam'));
    await tester.pumpAndSettle();
    // The old behaviour — tap re-sends immediately, no way to discard — is
    // exactly what must NOT happen now.
    expect(h.outbox.retried, isEmpty);
    expect(find.text(_s.retrySend), findsOneWidget);
    expect(find.text(_s.deleteMessage), findsOneWidget);
    expect(find.text(_s.messageNotSentTitle), findsOneWidget);

    await tester.tap(find.text(_s.retrySend));
    await tester.pumpAndSettle();
    expect(h.outbox.retried, [_clientKey]);
    expect(h.outbox.discarded, isEmpty);

    // And the other branch: Delete removes the queued message instead.
    await tester.tap(find.text(_s.notSentTapToRetry));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_s.deleteMessage));
    await tester.pumpAndSettle();
    expect(h.outbox.discarded, [_clientKey]);
    expect(h.outbox.retried, [_clientKey], reason: 'delete does not also send');

    await h.unmount(tester);
  });

  testWidgets('their typing bubble carries their profile picture', (tester) async {
    final h = _Harness(pending: const [], typingAdminAt: DateTime.now());
    await h.mount(tester);

    // The store has no avatar in this fixture, so the avatar falls back to
    // their initial — which is still the avatar slot, next to the dots.
    // One more frame for the store doc (an async stream) to land, so the
    // avatar has a name to fall back on.
    await tester.pump(_tick);
    expect(find.text(_s.typing), findsOneWidget, reason: 'they are typing');
    final avatar = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(CircleAvatar),
    );
    expect(
      avatar,
      findsOneWidget,
      reason: 'the picture sits beside the dots, inside the conversation',
    );
    // The store has no avatar in this fixture, so it falls back to their
    // initial — still the avatar slot, next to the dots.
    expect(
      find.descendant(of: avatar, matching: find.text('S')),
      findsOneWidget,
      reason: 'Shop → S',
    );

    await h.unmount(tester);
  });

  // The 5-second freshness rule itself, which both the thread and the inbox
  // row now apply (the thread re-evaluates it on its 1-second ticker, the row
  // on a one-shot timer armed for the exact expiry). DateTime.now() is real
  // wall-clock even under a widget test's fake async, so the rule is pinned
  // here as the pure function both call.
  test('a typing heartbeat goes stale after five seconds', () {
    final now = DateTime(2026, 9, 17, 12, 0);
    expect(typingFreshness, const Duration(seconds: 5));
    expect(isTypingFresh(null, now: now), isFalse);
    expect(
      isTypingFresh(now.subtract(const Duration(seconds: 4)), now: now),
      isTrue,
    );
    expect(
      isTypingFresh(now.subtract(const Duration(seconds: 6)), now: now),
      isFalse,
    );
  });

  // Which side's stamp each role watches: a customer sees the shop typing, a
  // store admin sees the customer typing — never their own heartbeat echoed
  // back at them.
  test('each side reads the other side\'s typing stamp', () {
    final at = DateTime(2026, 9, 17, 12, 0);
    final chat = {
      'typingUserAt': at.toUtc().toIso8601String(),
      'typingAdminAt': null,
    };
    expect(counterpartTypingAt(chat, viewerIsAdmin: true), at.toLocal());
    expect(counterpartTypingAt(chat, viewerIsAdmin: false), isNull);
  });
}
