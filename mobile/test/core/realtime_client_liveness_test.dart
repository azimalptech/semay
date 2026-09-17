// A server that accepts the socket and answers pings but never delivers —
// its Redis bus down (docs/08_OPERATIONS.md §3a) — used to be
// indistinguishable from a healthy one: `connected`, no caption, no retry,
// a thread frozen until the app was reopened. These drive the REAL
// RealtimeClient with a scripted socket and pin the fix: stalled within the
// snapshot deadline, the "Connecting…" condition true, a reconnect through
// the backoff, and the resync announcement the chat providers re-seed on.
//
// The second group pins the session-change guard: a token refresh for the
// same user is a no-op — also while a connect is in flight, which is where
// the old guard restarted the connect and, with a short TTL, looped through
// ~600 refreshes — while a logout or a login as someone else still turns
// the socket over.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/session.dart';

import '../support/fake_realtime.dart';

const _channel = 'chat:c1:messages';

/// Covers the backoff after one failure (2 s ± 50 %).
const _afterBackoff = Duration(seconds: 4);

/// A pump with no duration only flushes microtasks; the client's immediate
/// connect is a zero-length Timer, which needs the fake clock to move.
const _tick = Duration(milliseconds: 10);

ProviderContainer _container(MemSessionStore store, RealtimeSocketConnector connector) =>
    ProviderContainer(
      overrides: [
        secureSessionStoreProvider.overrideWithValue(store),
        realtimeSocketConnectorProvider.overrideWithValue(connector),
      ],
    );

/// Drops a listener WITHOUT awaiting the cancel. `StreamSubscription.cancel()`
/// on a controller-backed subscription does its work (onCancel — here the
/// unsubscribe frame and the deadline teardown) synchronously, but the Future
/// it hands back is `Future._nullFuture`, which dart:async builds in the ROOT
/// zone. Awaiting it inside `testWidgets` therefore resumes on the real event
/// loop instead of the binding's FakeAsync, the binding never sees the test
/// body finish, and the test sits there until the 10-minute timeout. That is
/// what wedged this file — and with it the whole `flutter test` run.
void _drop(StreamSubscription<Object?> sub) => unawaited(sub.cancel());

/// Advances the fake clock a second at a time until the client opens another
/// socket, and returns how long that took — the deadline it took to notice
/// plus the backoff it then waited. Bounded so a regression fails the
/// assertion instead of hanging the run.
Future<Duration> _timeToNextSocket(WidgetTester tester, FakeConnector connector) async {
  final before = connector.sockets.length;
  var waited = Duration.zero;
  const step = Duration(seconds: 1);
  const limit = Duration(seconds: 180);
  while (connector.sockets.length == before && waited < limit) {
    await tester.pump(step);
    waited += step;
  }
  return waited;
}

void main() {
  testWidgets('no snapshot within the deadline: stalled, reconnected, resynced', (
    tester,
  ) async {
    stubConnectivity();
    final connector = FakeConnector();
    final container = _container(
      MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
      connector.call,
    );
    final client = container.read(realtimeClientProvider);
    final states = <RealtimeConnectionState>[];
    final resyncs = <String>[];
    final events = <RealtimeEvent>[];
    final subs = [
      client.stateChanges.listen(states.add),
      client.resyncs.listen(resyncs.add),
      client.subscribe(_channel).listen(events.add),
    ];

    await tester.pump(_tick);
    expect(connector.sockets, hasLength(1));
    expect(connector.sockets.first.subscribed, [_channel]);
    expect(client.state, RealtimeConnectionState.connected);

    // Pings are answered: this is exactly the socket the old client called
    // healthy for good.
    unawaited(client.checkConnection());
    await tester.pump(const Duration(seconds: 1));
    expect(connector.sockets, hasLength(1));
    expect(client.state, RealtimeConnectionState.connected);

    // A whole deadline of sweeps with the subscribe outstanding and not one
    // frame delivered. Stops just short of the backoff's earliest retry (1 s
    // after the stall), so the resync announcement below can be pinned to the
    // NEW socket rather than to this one's death.
    await tester.pump(
      RealtimeClient.snapshotDeadline - const Duration(milliseconds: 500),
    );
    expect(states, contains(RealtimeConnectionState.stalled));
    expect(realtimeNeedsAttention(RealtimeConnectionState.stalled), isTrue,
        reason: 'stalled must show the "Connecting…" caption');
    expect(connector.sockets, hasLength(1));
    expect(connector.sockets.first.closed, isTrue);
    expect(resyncs, isEmpty, reason: 'nothing to resync until a new socket is up');

    await tester.pump(_afterBackoff);
    expect(connector.sockets, hasLength(2), reason: 'one reconnect through the backoff');
    expect(connector.sockets[1].subscribed, [_channel]);
    expect(resyncs, [_channel], reason: 'the re-subscribe is announced once');
    expect(client.state, RealtimeConnectionState.connected);

    // This time the server delivers: nothing is outstanding any more and the
    // socket outlives the deadline.
    connector.sockets[1].deliver({'channel': _channel, 'type': 'snapshot', 'data': <Object>[]});
    await tester.pump(
      RealtimeClient.snapshotDeadline + RealtimeClient.sweepInterval * 2,
    );
    expect(connector.sockets, hasLength(2));
    expect(client.state, RealtimeConnectionState.connected);
    expect(events.map((e) => e.type), [RealtimeEventType.snapshot]);
    expect(events.first.data, isEmpty);

    subs.forEach(_drop);
    container.dispose();
  });

  testWidgets('SUBSCRIBE_FAILED re-subscribes that channel first, stalls on the second; FORBIDDEN is delivered', (
    tester,
  ) async {
    stubConnectivity();
    final connector = FakeConnector();
    final container = _container(
      MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
      connector.call,
    );
    final client = container.read(realtimeClientProvider);
    final events = <RealtimeEvent>[];
    final sub = client.subscribe(_channel).listen(events.add);
    await tester.pump(_tick);
    expect(connector.sockets, hasLength(1));

    // The server's own verdict that its bus could not serve THIS subscribe.
    // One channel's failure must not cost every other channel on the socket a
    // reconnect and a REST re-seed, so the channel is re-subscribed on the
    // same connection first. Never shown to the consumer as an error.
    connector.sockets.first.deliver({'channel': _channel, 'type': 'error', 'error': 'SUBSCRIBE_FAILED'});
    await tester.pump(_tick);
    expect(client.state, RealtimeConnectionState.connected,
        reason: 'one channel failing is not the socket failing');
    expect(connector.sockets, hasLength(1));
    expect(connector.sockets.first.subscribed, [_channel, _channel]);
    // The unsubscribe goes first: the server may still hold the previous
    // attempt's placeholder, against which a bare re-subscribe is a no-op.
    expect(
      connector.sockets.first.sent.map((f) => f['type']).toList(),
      ['subscribe', 'unsubscribe', 'subscribe'],
    );
    expect(events, isEmpty);

    // Twice on one socket is the server, not the channel.
    connector.sockets.first.deliver({'channel': _channel, 'type': 'error', 'error': 'SUBSCRIBE_FAILED'});
    await tester.pump(_tick);
    expect(client.state, RealtimeConnectionState.stalled);
    expect(connector.sockets.first.closed, isTrue);
    expect(events, isEmpty);

    await tester.pump(_afterBackoff);
    expect(connector.sockets, hasLength(2));
    expect(client.state, RealtimeConnectionState.connected);

    // A final refusal is the consumer's to show, and does not touch the socket.
    connector.sockets[1].deliver({'channel': _channel, 'type': 'error', 'error': 'FORBIDDEN'});
    await tester.pump(
      RealtimeClient.snapshotDeadline + RealtimeClient.sweepInterval * 2,
    );
    expect(events.map((e) => e.error), ['FORBIDDEN']);
    expect(connector.sockets, hasLength(2));
    expect(client.state, RealtimeConnectionState.connected);

    _drop(sub);
    container.dispose();
  });

  testWidgets('a socket that is visibly delivering never stalls, and one that stops is retried at once', (
    tester,
  ) async {
    // The regression this pins: the deadline used to be a per-channel
    // stopwatch armed at subscribe time, so on an app launch every channel's
    // clock started in the same millisecond and one late snapshot dropped the
    // WHOLE socket. On a slow link (~20 snapshots serialised over one TCP
    // connection, a 200-message thread window alone ~165 KB) that fired on a
    // perfectly healthy server, and the reconnect re-requested all of it —
    // "Connecting…" forever on a connection that was working.
    //
    // And the second half: a stall only ever incremented _failures, never
    // resetting it the way a drop does, so a socket that had been delivering
    // for a minute was retried on the saturated ~30 s backoff.
    stubConnectivity();
    final connector = FakeConnector();
    final container = _container(
      MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
      connector.call,
    );
    final client = container.read(realtimeClientProvider);
    const busy = 'user:u1:chats';
    final states = <RealtimeConnectionState>[];
    final subs = [
      client.stateChanges.listen(states.add),
      client.subscribe(_channel).listen((_) {}),
      client.subscribe(busy).listen((_) {}),
    ];
    await tester.pump(_tick);
    expect(connector.sockets, hasLength(1));
    expect(connector.sockets.first.subscribed, [_channel, busy]);

    // Five stalls in a row on servers that deliver nothing at all. This is the
    // condition the backoff exists for, and it must still grow: by the fifth,
    // the wait is the 30 s cap ±50 %.
    var lastDeadWait = Duration.zero;
    for (var i = 0; i < 5; i++) {
      lastDeadWait = await _timeToNextSocket(tester, connector);
      expect(connector.sockets, hasLength(i + 2));
    }
    expect(lastDeadWait, greaterThan(const Duration(seconds: 35)),
        reason: 'a server that never delivers must be backed off, hard');

    // Now a server that works. `busy` is served every 3 s; `_channel` stays
    // unanswered for a full minute — well over twice the deadline — and the
    // socket must survive, because the socket is visibly delivering.
    final socket = connector.sockets.last;
    expect(socket.closed, isFalse);
    final stallsBefore =
        states.where((s) => s == RealtimeConnectionState.stalled).length;
    socket.deliver({'channel': busy, 'type': 'snapshot', 'data': <Object>[]});
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 3));
      socket.deliver({
        'channel': busy,
        'type': 'upsert',
        'data': {'id': 'c$i'},
      });
    }
    expect(states.where((s) => s == RealtimeConnectionState.stalled).length,
        stallsBefore,
        reason: 'a slow channel must not kill a socket that is delivering');
    expect(socket.closed, isFalse);

    // Then it goes quiet with that subscribe still outstanding. The deadline
    // still applies — but this socket HAD been delivering, so the retry after
    // it costs ~1–3 s, not the saturated backoff the five dead sockets above
    // had built up and that _stall used to keep forever.
    final workedWait = await _timeToNextSocket(tester, connector);
    expect(states.where((s) => s == RealtimeConnectionState.stalled).length,
        stallsBefore + 1);
    expect(socket.closed, isTrue);
    expect(workedWait, lessThan(const Duration(seconds: 35)),
        reason: 'a socket that worked and then died is retried at once');
    expect(workedWait, lessThan(lastDeadWait));

    subs.forEach(_drop);
    container.dispose();
  });

  group('session changes', () {
    testWidgets('a same-user refresh is a no-op; logout and another login turn the socket over', (
      tester,
    ) async {
      stubConnectivity();
      final connector = FakeConnector();
      final store = MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1');
      final container = _container(store, connector.call);
      // The app has a stored session before anything subscribes.
      await container.read(sessionControllerProvider.future);
      final client = container.read(realtimeClientProvider);
      final sub = client.subscribe(_channel).listen((_) {});
      await tester.pump(_tick);
      expect(connector.sockets, hasLength(1));
      final epoch = client.sessionEpoch;

      // A refresh: new tokens, new SessionClaims object, same user.
      await container
          .read(sessionControllerProvider.notifier)
          .setTokens(accessToken: fakeJwt('u1'), refreshToken: 'r2');
      await tester.pump(_tick);
      expect(client.sessionEpoch, epoch);
      expect(connector.sockets, hasLength(1));
      expect(connector.sockets.first.closed, isFalse);

      await container.read(sessionControllerProvider.notifier).logout();
      await tester.pump(_tick);
      expect(client.sessionEpoch, epoch + 1);
      expect(connector.sockets.first.closed, isTrue);
      expect(client.state, RealtimeConnectionState.disconnected);

      await container
          .read(sessionControllerProvider.notifier)
          .setTokens(accessToken: fakeJwt('u2'), refreshToken: 'r3');
      await tester.pump(_tick);
      expect(client.sessionEpoch, epoch + 2);
      expect(connector.sockets, hasLength(2), reason: 'a new socket under the new identity');
      expect(client.state, RealtimeConnectionState.connected);

      _drop(sub);
      container.dispose();
    });

    testWidgets('a refresh that lands while the connect is in flight keeps that socket', (
      tester,
    ) async {
      stubConnectivity();
      final pending = <Completer<RealtimeSocket>>[];
      final sockets = <FakeSocket>[];
      final store = MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1');
      final container = _container(store, (uri) {
        final c = Completer<RealtimeSocket>();
        pending.add(c);
        return c.future;
      });
      await container.read(sessionControllerProvider.future);
      final client = container.read(realtimeClientProvider);
      final sub = client.subscribe(_channel).listen((_) {});
      await tester.pump(_tick);
      expect(pending, hasLength(1));

      // The connect refreshed before opening the socket: the session state
      // is replaced while the handshake is still running.
      await container
          .read(sessionControllerProvider.notifier)
          .setTokens(accessToken: fakeJwt('u1'), refreshToken: 'r2');
      await tester.pump(_tick);

      final socket = FakeSocket();
      sockets.add(socket);
      pending.first.complete(socket);
      await tester.pump(_tick);
      expect(socket.closed, isFalse, reason: 'the socket it just opened is kept');
      expect(socket.subscribed, [_channel]);
      expect(pending, hasLength(1), reason: 'no second handshake');
      expect(client.state, RealtimeConnectionState.connected);

      _drop(sub);
      container.dispose();
    });
  });

  // Every resync announcement costs the server a REST re-seed per consumer
  // (the thread window, the chat list, each admin store list). A flapping
  // network reconnects far faster than a stall does, and that burst used to
  // land, unlimited, on the component already struggling.
  group('the resync announcement is rate-limited per channel', () {
    testWidgets('back-to-back reconnects announce once; a later one announces again', (
      tester,
    ) async {
      stubConnectivity();
      final connector = FakeConnector();
      final container = _container(
        MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
        connector.call,
      );
      final client = container.read(realtimeClientProvider);
      final resyncs = <String>[];
      final subs = [
        client.resyncs.listen(resyncs.add),
        client.subscribe(_channel).listen((_) {}),
      ];
      await tester.pump(_tick);
      expect(connector.sockets, hasLength(1));
      expect(resyncs, isEmpty, reason: 'the first subscribe is not a resync');

      // Reconnects, back to back. Driven through onSessionChanged because it
      // reconnects immediately and deterministically — the announcement path
      // is the same one every reconnect takes (_connect's re-subscribe loop).
      client.onSessionChanged('u2');
      await tester.pump(_tick);
      expect(connector.sockets, hasLength(2));
      expect(resyncs, [_channel], reason: 'the re-subscribe is announced');

      // Two more inside the window. Each really does re-subscribe (the socket
      // is new and the server owes a fresh snapshot), but no consumer is told
      // to spend a REST call on it.
      client.onSessionChanged('u3');
      await tester.pump(_tick);
      client.onSessionChanged('u4');
      await tester.pump(_tick);
      expect(connector.sockets, hasLength(4), reason: 'it did keep reconnecting');
      expect(connector.sockets.last.subscribed, [_channel]);
      expect(resyncs, [_channel], reason: 'still one announcement inside the window');

      // Past the window, the next reconnect is announced again — this is a
      // rate limit, not a mute. (It is also shorter than the 25 s stall cycle,
      // so a socket that reconnects and still delivers nothing is never
      // starved of its re-seed.)
      await tester.pump(RealtimeClient.resyncInterval);
      client.onSessionChanged('u5');
      await tester.pump(_tick);
      expect(connector.sockets, hasLength(5));
      expect(resyncs, [_channel, _channel]);

      subs.forEach(_drop);
      container.dispose();
    });
  });
}
