// End to end through the real pieces — ChatThreadScreen, mergedChatMessages-
// Provider, ChatMessagesNotifier, RealtimeClient — with only the platform
// edges faked (test/support/fake_realtime.dart): what a sender sees under
// their bubbles as receipts land, and what the thread does when the socket
// stops delivering.
//
// The receipts protocol itself was proven against a live server by a
// two-client matrix (every state, both roles); this pins the surface the
// user actually looks at, which that matrix could not: a `receipts` roll-up
// for OLDER messages re-renders their ticks at once, and "Seen HH:MM" sits
// under the newest message only, only while that message is mine and read.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/app_icon.dart';
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
import 'package:semay/services/chat_service.dart';

import '../support/fake_realtime.dart';

const _chatId = 'u1_s1';
const _channel = 'chat:$_chatId:messages';
const _s = S(false);

/// Covers the backoff after one failure (2 s ± 50 %).
const _afterBackoff = Duration(seconds: 4);

/// A pump with no duration only flushes microtasks; the client's immediate
/// connect is a zero-length Timer, which needs the fake clock to move.
const _tick = Duration(milliseconds: 10);

Map<String, dynamic> _message(int id, {String senderRole = 'user'}) => {
  'id': '$id',
  'chatId': _chatId,
  'senderId': senderRole == 'user' ? 'u1' : 'admin-1',
  'senderRole': senderRole,
  'text': 'message $id',
  'createdAt': '2026-09-16T08:0$id:00.000Z',
  'deliveredAt': null,
  'readAt': null,
};

/// [upTo] null is the wire's "this receipt stamped nothing" — the server sends
/// it verbatim as JSON null (bus.ts documents the field, chats/service.ts
/// returns `bound?.toString() ?? null`).
Map<String, dynamic> _receipts(String status, {required int? upTo, String senderRole = 'user'}) => {
  'channel': _channel,
  'type': 'receipts',
  'data': {
    'senderRole': senderRole,
    'status': status,
    'at': '2026-09-16T09:15:00.000Z',
    'upToMessageId': upTo == null ? null : '$upTo',
    'fromMessageId': null,
  },
};

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  var messages = <Map<String, dynamic>>[];
  var windowGets = 0;
  final receipts = <String>[];
  /// Stands in for what the real server does after a receipts POST: stamp the
  /// rows and publish the roll-up. Without it the thread's "is there anything
  /// unread" gate never closes, which is not how the server behaves.
  void Function()? afterReceipts;

  /// A real receipts POST is a network round trip and a `prisma.$transaction`.
  /// The builds that fire inside that window are the whole point of the
  /// in-flight guard, so the fake has to have a window at all.
  Duration receiptsDelay = Duration.zero;
  /// Every value PATCH /users/me carried for `activeChatId`, in order — the
  /// server-side half of "which thread is on screen".
  final activeChats = <String?>[];

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/chats/$_chatId/messages') {
      windowGets++;
      return {'messages': messages.reversed.toList()}; // newest-first, as served
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    if (path.endsWith('/receipts')) {
      receipts.add((body! as Map)['status'] as String);
      if (receiptsDelay > Duration.zero) await Future<void>.delayed(receiptsDelay);
      afterReceipts?.call();
    }
    return {'ok': true};
  }

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

class _Thread {
  final api = _FakeApi();
  final connector = FakeConnector();
  late final ProviderContainer container;

  FakeSocket get socket => connector.sockets.last;

  Future<void> mount(WidgetTester tester) async {
    stubConnectivity();
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
            'storeId': 's1',
            'unreadByUser': 0,
            'unreadByAdmin': 0,
          }),
        ),
        storeDocProvider.overrideWith(
          (ref, id) => Stream.value({'id': id, 'name': 'Shop', 'avatarUrl': '', 'phone': ''}),
        ),
        userDocProvider.overrideWith((ref, id) async => null),
        pendingMessagesProvider.overrideWith((ref, id) => Stream.value(const <OutboxItem>[])),
      ],
    );
    // A stored session before anything subscribes, as on a warm launch.
    await container.read(sessionControllerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ChatThreadScreen(chatId: _chatId)),
      ),
    );
    await tester.pump(_tick); // REST seed + socket connect
  }

  /// The screen first, then the container, so no socket timer outlives the
  /// test.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }
}

/// The status marks on screen, keyed by the message text they sit under.
Map<String, AppIcon> _ticks(WidgetTester tester) {
  final result = <String, AppIcon>{};
  for (final element in find.byType(MessageStatusTicks).evaluate()) {
    final bubble = find.ancestor(of: find.byWidget(element.widget), matching: find.byType(Column)).first;
    final text = find.descendant(of: bubble, matching: find.textContaining('message ')).evaluate().first.widget as Text;
    final icon = find.descendant(of: find.byWidget(element.widget), matching: find.byType(AppIcon));
    result[text.data!] = tester.widget<AppIcon>(icon);
  }
  return result;
}

void main() {
  testWidgets('receipts for older messages re-render their ticks; Seen only under the newest', (
    tester,
  ) async {
    final t = _Thread()..api.messages = [_message(1), _message(2)];
    await t.mount(tester);
    expect(t.socket.subscribed, [_channel]);
    expect(find.text(_s.connecting), findsNothing);

    // Sent: one grey check under each of my messages.
    var ticks = _ticks(tester);
    expect(ticks.keys, unorderedEquals(['message 1', 'message 2']));
    expect(ticks.values.map((i) => i.name), everyElement('check'));
    expect(ticks.values.map((i) => i.color), everyElement(AppColors.textSecondary));

    // Their chat list stamped delivery: a roll-up, one frame for both rows.
    t.socket.deliver(_receipts('delivered', upTo: 2));
    await tester.pump(_tick);
    ticks = _ticks(tester);
    expect(ticks.values.map((i) => i.name), everyElement('check_double'));
    expect(ticks.values.map((i) => i.color), everyElement(AppColors.textSecondary));
    expect(find.textContaining(_s.seenAt('')), findsNothing);

    // They read only up to the older one (a message that arrived after
    // their receipt was stamped is not in its set).
    t.socket.deliver(_receipts('read', upTo: 1));
    await tester.pump(_tick);
    ticks = _ticks(tester);
    expect(ticks['message 1']!.color, AppColors.readTick);
    expect(ticks['message 2']!.color, AppColors.textSecondary);
    expect(find.textContaining(_s.seenAt('')), findsNothing,
        reason: 'Seen belongs under the newest message, which is not read');

    t.socket.deliver(_receipts('read', upTo: 2));
    await tester.pump(_tick);
    ticks = _ticks(tester);
    expect(ticks.values.map((i) => i.color), everyElement(AppColors.readTick));
    expect(find.textContaining(_s.seenAt('')), findsOneWidget);

    // Their reply is now the newest: no caption, no mark on their bubble,
    // and the thread marks it read for them.
    t.socket.deliver({'channel': _channel, 'type': 'upsert', 'data': _message(3, senderRole: 'admin')});
    await tester.pump(_tick);
    expect(find.text('message 3'), findsOneWidget);
    expect(find.textContaining(_s.seenAt('')), findsNothing);
    expect(_ticks(tester).keys, unorderedEquals(['message 1', 'message 2']));
    expect(t.api.receipts, contains('read'));

    await t.unmount(tester);
  });

  // Opening a thread is one read receipt, not three. The gate in
  // _syncReadStatus ("is anything of theirs still unread") stays true until
  // the server's answer comes back and republishes the thread, and several
  // builds happen inside that window — the REST seed, the socket snapshot,
  // the chat-doc upsert — so every one of them fired its own POST, each a
  // full transaction with an updateMany on the server.
  testWidgets('opening a thread with unread messages posts exactly one read receipt', (
    tester,
  ) async {
    final t = _Thread()
      ..api.messages = [_message(1, senderRole: 'admin')]
      ..api.receiptsDelay = const Duration(milliseconds: 200);
    // The server stamps every visible unread row inside its transaction, so a
    // message that arrived before the answer is covered by the same receipt.
    t.api.afterReceipts = () {
      if (t.connector.sockets.isEmpty) return;
      t.socket.deliver(_receipts('read', upTo: 2, senderRole: 'admin'));
    };
    await t.mount(tester);

    // Builds inside the in-flight window: the socket snapshot, and one of
    // their messages arriving. Each one re-enters _syncReadStatus with the
    // gate still open, because nothing has come back to close it yet.
    t.socket.deliver({
      'channel': _channel,
      'type': 'snapshot',
      'data': [_message(1, senderRole: 'admin')],
    });
    await tester.pump(_tick);
    t.socket.deliver({
      'channel': _channel,
      'type': 'upsert',
      'data': _message(2, senderRole: 'admin'),
    });
    await tester.pump(_tick);
    expect(t.api.receipts, ['read'], reason: 'still one call in flight');

    // The answer lands and closes the gate.
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 4; i++) {
      await tester.pump(_tick);
    }
    expect(t.api.receipts, ['read']);

    // Their NEXT message re-arms it — this is a guard, not a mute.
    t.api.afterReceipts = () {
      if (t.connector.sockets.isEmpty) return;
      t.socket.deliver(_receipts('read', upTo: 3, senderRole: 'admin'));
    };
    t.socket.deliver({
      'channel': _channel,
      'type': 'upsert',
      'data': _message(3, senderRole: 'admin'),
    });
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 4; i++) {
      await tester.pump(_tick);
    }
    expect(t.api.receipts, ['read', 'read']);

    // Let that second call's own delay elapse before the tree goes away, or
    // the binding reports its timer as leaked.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(_tick);
    await t.unmount(tester);
  });

  // The bound is the whole safety of the protocol: `upToMessageId` is the
  // newest row the server actually stamped, and NULL means it stamped none.
  // Reading null as "no upper bound" is the exact false "Seen" the bound
  // exists to prevent — and the server does emit that frame (a read receipt
  // that stamped no message but cleared a non-zero unread counter).
  testWidgets('a receipts roll-up that stamped nothing (upToMessageId null) changes no tick', (
    tester,
  ) async {
    final t = _Thread()..api.messages = [_message(1), _message(2)];
    await t.mount(tester);

    var ticks = _ticks(tester);
    expect(ticks.values.map((i) => i.name), everyElement('check'));
    expect(ticks.values.map((i) => i.color), everyElement(AppColors.textSecondary));

    t.socket.deliver(_receipts('read', upTo: null));
    await tester.pump(_tick);
    ticks = _ticks(tester);
    expect(ticks.keys, unorderedEquals(['message 1', 'message 2']));
    expect(ticks.values.map((i) => i.name), everyElement('check'),
        reason: 'nothing was stamped, so nothing may show as delivered');
    expect(ticks.values.map((i) => i.color), everyElement(AppColors.textSecondary));
    expect(find.textContaining(_s.seenAt('')), findsNothing);

    // A `delivered` roll-up with a null bound is just as empty.
    t.socket.deliver(_receipts('delivered', upTo: null));
    await tester.pump(_tick);
    expect(_ticks(tester).values.map((i) => i.name), everyElement('check'));

    // And a real bound still lands, so this is a guard, not a mute.
    t.socket.deliver(_receipts('read', upTo: 2));
    await tester.pump(_tick);
    expect(_ticks(tester).values.map((i) => i.color), everyElement(AppColors.readTick));

    await t.unmount(tester);
  });

  testWidgets('a stalled socket shows Connecting… and the reconnect re-seeds over REST', (
    tester,
  ) async {
    final t = _Thread()..api.messages = [_message(1)];
    await t.mount(tester);
    expect(t.api.windowGets, 1);
    expect(find.text('message 1'), findsOneWidget);
    expect(find.text(_s.connecting), findsNothing);

    // The server never answers the subscribe; meanwhile a message lands
    // that the dead bus will never push.
    t.api.messages = [_message(1), _message(2, senderRole: 'admin')];
    await tester.pump(RealtimeClient.snapshotDeadline);
    expect(find.text(_s.connecting), findsOneWidget);
    expect(find.text('message 2'), findsNothing);
    expect(t.api.windowGets, 1, reason: 'no fetch until the reconnect');

    await tester.pump(_afterBackoff);
    expect(t.connector.sockets, hasLength(2));
    expect(t.socket.subscribed, [_channel]);
    expect(t.api.windowGets, 2, reason: 'the resync re-fetches the window');
    await tester.pump(_tick);
    expect(find.text('message 2'), findsOneWidget);
    expect(find.text(_s.connecting), findsNothing);

    await t.unmount(tester);
  });

  // Leaving the thread has to put activeChatId back to null, or the rule in
  // notification_service.dart ("silent ONLY when its chatId equals the thread
  // on screen") keeps matching a thread nobody is looking at and every later
  // message from this chat arrives silently.
  //
  // It regressed invisibly: dispose() read chatServiceProvider off `ref`, and
  // flutter_riverpod throws a StateError for real — not an assert — once the
  // element is defunct, which StatefulElement.unmount() makes it BEFORE
  // calling State.dispose(). So the very first line threw and took the whole
  // of dispose with it: no setActiveChat(null), and the 1-second staleness
  // Timer, the composer's TextEditingController and the ScrollController all
  // leaked, one set per thread opened.
  testWidgets('leaving the thread clears the active chat and leaves no timer behind', (
    tester,
  ) async {
    final t = _Thread()..api.messages = [_message(1)];
    await t.mount(tester);
    // The server mirror of the flag is debounced (chat_service.dart — it is
    // diagnostic-only, and every route pushed over the thread runs through
    // it); the flag the push handler reads is set synchronously and is
    // pinned in test/services/active_chat_stack_test.dart.
    await tester.pump(ChatService.activeChatMirrorDelay);
    expect(t.api.activeChats, [_chatId], reason: 'entering claims the thread');

    // Unmounted but the container kept alive, exactly as in the app: the
    // ChatService outlives any one thread screen, so the release really does
    // reach the server.
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull, reason: 'dispose ran to the end');
    // The staleness Timer ticks every second and calls setState; had dispose
    // aborted before cancelling it, this pump would fire it on a dead State.
    // It also carries the mirror past its debounce.
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    expect(t.api.activeChats, [_chatId, null]);
    t.container.dispose();
  });
}
