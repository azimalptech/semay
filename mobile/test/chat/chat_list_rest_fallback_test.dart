// The chat list was cache + socket only: with the socket up but its server
// not delivering (docs/08_OPERATIONS.md §3a) a fresh install showed an
// empty list for good. Drives the real userChatsProvider with a scripted
// socket and a fake REST: the REST copy paints when the snapshot never
// comes (and still stamps delivery for what it brought), the socket
// supersedes an answer it overtook, and every reconnect re-fetches.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/chat_cache.dart';
import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/chat/chat_providers.dart';

import '../support/fake_realtime.dart';

const _channel = 'user:u1:chats';

/// Covers the backoff after one failure (2 s ± 50 %).
const _afterBackoff = Duration(seconds: 4);

/// A pump with no duration only flushes microtasks; the client's immediate
/// connect is a zero-length Timer, which needs the fake clock to move.
const _tick = Duration(milliseconds: 10);

Map<String, dynamic> _chat(String id, {int unreadByUser = 0}) => {
  'id': id,
  'userId': 'u1',
  'storeId': 'store-$id',
  'unreadByUser': unreadByUser,
  'unreadByAdmin': 0,
  'lastMessageAt': '2026-09-16T08:00:00.000Z',
};

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  /// What GET /chats answers with — a future, so a test can hold it open.
  Future<List<Map<String, dynamic>>> Function() chats = () async => const [];
  var listGets = 0;
  final receipts = <String>[];

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/chats') {
      listGets++;
      return {'chats': await chats()};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    if (path.endsWith('/receipts')) receipts.add((body! as Map)['status'] as String);
    return {'ok': true};
  }
}

class _FakeSession extends SessionController {
  @override
  Future<SessionClaims?> build() async =>
      const SessionClaims(uid: 'u1', role: 'user', storeIds: [], claimsVersion: 1);
}

class _List {
  final api = _FakeApi();
  final connector = FakeConnector();
  late final ProviderContainer container;
  final seen = <List<String>>[];

  FakeSocket get socket => connector.sockets.last;
  List<String> get ids => seen.isEmpty ? const [] : seen.last;

  Future<void> start(WidgetTester tester) async {
    stubConnectivity();
    container = ProviderContainer(
      overrides: [
        sessionControllerProvider.overrideWith(_FakeSession.new),
        secureSessionStoreProvider.overrideWithValue(
          MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
        ),
        apiClientProvider.overrideWithValue(api),
        chatCacheProvider.overrideWithValue(MemChatCache()),
        realtimeSocketConnectorProvider.overrideWithValue(connector.call),
      ],
    );
    await container.read(sessionControllerProvider.future);
    container.listen(userChatsProvider, (_, next) {
      final value = next.value;
      if (value != null) seen.add(value.map((c) => c.id).toList());
    }, fireImmediately: true);
    await tester.pump(_tick);
  }
}

void main() {
  testWidgets('REST paints the list when the snapshot never comes, and again on every reconnect', (
    tester,
  ) async {
    final t = _List()..api.chats = () async => [_chat('a', unreadByUser: 2), _chat('b')];
    await t.start(tester);
    expect(t.socket.subscribed, [_channel]);
    // The fallback is ARMED, not spent: a launch where the socket answers
    // normally must not also pay a full chat-list query (and an admin of four
    // stores must not pay four).
    expect(t.api.listGets, 0, reason: 'the grace has not elapsed yet');
    expect(t.ids, isEmpty);

    await tester.pump(chatListRestSeedGrace);
    expect(t.ids, ['a', 'b']);
    expect(t.api.listGets, 1);
    expect(t.api.receipts, ['delivered'], reason: 'a rise seen over REST is a delivery too');

    // The grace above already spent part of the silence window — pump the
    // REMAINDER, so the stall lands on the sweep at exactly snapshotDeadline
    // and is read before its backoff reconnects. (A REST answer is not a
    // delivery and deliberately does not reset the silence clock.)
    await tester.pump(RealtimeClient.snapshotDeadline - chatListRestSeedGrace);
    expect(t.container.read(realtimeClientProvider).state, RealtimeConnectionState.stalled);
    await tester.pump(_afterBackoff);
    expect(t.connector.sockets, hasLength(2));
    await tester.pump(chatListRestSeedGrace);
    expect(t.api.listGets, 2, reason: 'the resync re-fetches the list');

    // Nothing to re-stamp: the counts did not rise.
    expect(t.api.receipts, ['delivered']);
    t.container.dispose();
  });

  testWidgets('a snapshot inside the grace costs no GET at all', (tester) async {
    final t = _List()..api.chats = () async => [_chat('never-asked-for')];
    await t.start(tester);

    t.socket.deliver({'channel': _channel, 'type': 'snapshot', 'data': [_chat('live')]});
    await tester.pump(_tick);
    expect(t.ids, ['live']);

    // Well past the grace, and past a second one: the socket spoke, so the
    // fallback is never spent — not at launch and not later.
    await tester.pump(chatListRestSeedGrace * 2);
    expect(t.api.listGets, 0);
    expect(t.ids, ['live']);

    t.container.dispose();
  });

  testWidgets('a snapshot that overtakes the REST answer wins', (tester) async {
    final rest = Completer<List<Map<String, dynamic>>>();
    final t = _List()..api.chats = () => rest.future;
    await t.start(tester);
    expect(t.ids, isEmpty);

    // Silence through the grace, so the fallback does go out — and is then
    // still in flight when the socket finally speaks.
    await tester.pump(chatListRestSeedGrace);
    expect(t.api.listGets, 1);

    t.socket.deliver({'channel': _channel, 'type': 'snapshot', 'data': [_chat('live')]});
    await tester.pump(_tick);
    expect(t.ids, ['live']);

    // The stale answer lands after the socket has spoken: dropped, not merged.
    rest.complete([_chat('stale-1'), _chat('stale-2')]);
    await tester.pump(_tick);
    expect(t.ids, ['live']);

    t.container.dispose();
  });
}
