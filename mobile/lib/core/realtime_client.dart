import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';

import 'api_client.dart';
import 'session.dart';

enum RealtimeEventType { snapshot, upsert, remove, receipts, error }

/// One frame off the multiplexed WS connection — see docs/07_MIGRATION.md's
/// realtime gateway section. `snapshot` always arrives first after a
/// subscribe (current state, same role Firestore's first listener emission
/// played); `upsert`/`remove` are incremental diffs after that. `receipts` is
/// the chat-thread roll-up ("every message from side X up to id N is now
/// delivered/read as of T") that replaced re-sending the whole thread on each
/// receipt.
class RealtimeEvent {
  const RealtimeEvent({required this.type, this.data, this.removedId, this.error});

  final RealtimeEventType type;
  final dynamic data;
  final String? removedId;
  final String? error;

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'snapshot':
        return RealtimeEvent(type: RealtimeEventType.snapshot, data: json['data']);
      case 'upsert':
        return RealtimeEvent(type: RealtimeEventType.upsert, data: json['data']);
      case 'remove':
        return RealtimeEvent(type: RealtimeEventType.remove, removedId: json['id'] as String?);
      case 'receipts':
        return RealtimeEvent(type: RealtimeEventType.receipts, data: json['data']);
      default:
        return RealtimeEvent(type: RealtimeEventType.error, error: json['error'] as String?);
    }
  }
}

/// What the socket is doing right now. Surfaced in the chat UI the way
/// WhatsApp/Telegram show "Connecting…" under the title — so a stalled
/// thread reads as "the network is down", not "the app is broken".
///
/// `idle` = nothing has asked for a channel, so there is deliberately no
/// socket (a superadmin with no stores never subscribes to anything); the UI
/// must not read that as "connecting".
///
/// `stalled` = the socket is open and answers pings, but with at least one
/// subscribe outstanding it has delivered NOTHING for
/// [RealtimeClient.snapshotDeadline]: the server accepted the connection and
/// is not delivering (its Redis bus down or unreachable — the "messages only
/// show up after I reopen the app" report, docs/08_OPERATIONS.md §3a). Before
/// this state existed that was indistinguishable from `connected`: the
/// caption never showed and nothing ever retried. It is handled as a failure
/// — the socket is closed and reconnected with the same backoff as a drop.
enum RealtimeConnectionState { idle, disconnected, connecting, connected, stalled }

/// What [RealtimeClient] needs from a socket — narrow on purpose, so the
/// liveness tests can hand it a scripted one (a socket that answers pings but
/// never sends a snapshot) while the app keeps [IOWebSocketChannel].
abstract class RealtimeSocket {
  Stream<dynamic> get stream;
  void send(String frame);
  Future<void> close();
  int? get closeCode;
  String? get closeReason;
}

typedef RealtimeSocketConnector = Future<RealtimeSocket> Function(Uri uri);

class _IoWebSocket implements RealtimeSocket {
  _IoWebSocket(this._channel);

  final IOWebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;
  @override
  void send(String frame) => _channel.sink.add(frame);
  @override
  Future<void> close() => _channel.sink.close();
  @override
  int? get closeCode => _channel.closeCode;
  @override
  String? get closeReason => _channel.closeReason;
}

Future<RealtimeSocket> _connectIoWebSocket(Uri uri) async {
  final channel = IOWebSocketChannel.connect(
    uri,
    // dart:io's own heartbeat: a ping every interval, and if the peer hasn't
    // answered by the next one the socket is closed for us — which lands in
    // RealtimeClient._onClosed and reconnects.
    pingInterval: RealtimeClient._pingInterval,
    connectTimeout: RealtimeClient._connectTimeout,
  );
  await channel.ready;
  return _IoWebSocket(channel);
}

/// Overridden by the liveness tests (test/core/realtime_client_liveness_test
/// .dart); the app never touches it.
final realtimeSocketConnectorProvider = Provider<RealtimeSocketConnector>(
  (ref) => _connectIoWebSocket,
);

/// One WS connection, ref-counted per channel. `subscribe(channel)` sends a
/// `subscribe` frame on the first listener and `unsubscribe` when the last
/// one cancels — wrapping this in `StreamProvider.family(..., isAutoDispose:
/// true)` (see e.g. chat_providers.dart) makes Riverpod's own autoDispose
/// transparently become the real WS unsubscribe, reproducing Firestore's
/// per-listener economics exactly. Consumers must cancel their listener
/// synchronously on dispose (an explicit `.listen` + `ref.onDispose`, not an
/// `async*` generator, whose cancel only lands at its next yield) — otherwise
/// a rebuilt consumer finds the old listener still attached, `onListen` never
/// fires again, and it sits on a channel that will never send it a snapshot.
///
/// The connection itself is treated as something that WILL die, repeatedly,
/// without saying so — that is what a phone's network looks like (carrier
/// NAT resets, Doze, Wi-Fi↔LTE handovers, the OS suspending the process).
/// Four things keep it alive that the first version lacked, and each one
/// corresponded to a way chat silently stopped updating until app restart:
///
///  * a heartbeat (`pingInterval`): a socket that stops answering pings is
///    closed and reconnected instead of sitting "open" forever;
///  * a fresh token per connect: the access JWT lives 15 minutes, and a
///    reconnect that reused the stored one after that was refused (4401) and
///    retried with the same dead token every 2 s, indefinitely;
///  * reconnect on failure with backoff — a connect that threw never
///    scheduled a retry at all — plus an immediate probe on app resume and on
///    network change, so messages sent while the phone was in a pocket land
///    the moment the screen turns on;
///  * a new socket per session: the socket authenticates once, so a logout/
///    login had the new user requesting their channels over the old user's
///    identity and being refused;
///  * a silence deadline while a subscribe is outstanding: a socket whose
///    server accepts the connection and answers pings but never delivers (its
///    Redis bus down — docs/08_OPERATIONS.md §3a) looked exactly like a
///    healthy one, so the thread sat frozen with no caption and no retry
///    until the app was reopened. Such a socket is now `stalled`: dropped and
///    reconnected through the backoff, and every reconnect announces the
///    channels it re-subscribed on [resyncs] so their consumers re-fetch over
///    REST. A single channel the server refuses to serve is retried on its
///    own first ([RealtimeClient.snapshotDeadline]) — one late `post:`
///    snapshot must never cost the chat thread its connection.
class RealtimeClient {
  RealtimeClient(this._ref, {String? sessionUid}) : _sessionUid = sessionUid {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) unawaited(checkConnection());
    });
  }

  final Ref _ref;
  final Map<String, StreamController<RealtimeEvent>> _controllers = {};
  final _random = Random();

  final StreamController<RealtimeConnectionState> _stateChanges =
      StreamController<RealtimeConnectionState>.broadcast();
  RealtimeConnectionState _state = RealtimeConnectionState.disconnected;

  /// Effective state — `idle` while nobody wants a channel.
  RealtimeConnectionState get state =>
      _controllers.isEmpty &&
          (_state == RealtimeConnectionState.disconnected ||
              _state == RealtimeConnectionState.stalled)
      ? RealtimeConnectionState.idle
      : _state;
  Stream<RealtimeConnectionState> get stateChanges => _stateChanges.stream;

  /// Channel names whose subscribe frame was re-sent on a NEW socket — after
  /// a drop, a stall or a session change. Consumers that also hold a REST
  /// copy of the channel's state re-fetch it on this (chat_providers.dart):
  /// the snapshot a resubscribe should produce may never come (the very
  /// condition `stalled` detects), and nothing else replays what arrived
  /// while the socket was down. Not fired for a channel's first subscribe —
  /// its consumer's build() already seeds from REST.
  Stream<String> get resyncs => _resyncs.stream;
  final StreamController<String> _resyncs = StreamController<String>.broadcast();
  final Set<String> _everSubscribed = {};

  // Channels announced on `resyncs` too recently to announce again, each with
  // the timer that clears it. Every announcement costs the server a DB-backed
  // REST re-seed per consumer (the open thread's window, the chat list, each
  // admin store list), and it is announced on EVERY reconnect — so a server
  // brown-out, which is exactly when reconnects come thick and fast, had every
  // phone answering with extra queries aimed at the component already failing.
  // The same amplification the token refresh got a circuit breaker for
  // (api_client.dart RefreshCircuitBreaker).
  //
  // A timer rather than a stored DateTime, for the same reason _quietSweeps
  // counts ticks: the rule is then driven purely by timers, which is what a
  // widget test's fake clock can advance and what the app's own suspension
  // stops along with everything else.
  final Map<String, Timer> _resyncCooldown = {};

  // Channels with a subscribe frame out and no snapshot back yet. Something
  // in here is what makes silence meaningful: with nothing outstanding, a
  // quiet socket is just a quiet conversation.
  final Set<String> _awaitingSnapshot = {};

  // Subscribe attempts for a channel ON THE CURRENT SOCKET. A server that
  // answers SUBSCRIBE_FAILED for one channel gets that channel re-subscribed
  // once before the whole socket is written off — see _retryOrStall.
  final Map<String, int> _subscribeAttempts = {};

  // Consecutive [sweepInterval] ticks with a subscribe outstanding and not one
  // delivered frame. Counted in ticks rather than measured against
  // DateTime.now() so the rule is driven purely by timers — which is what a
  // widget test's fake clock can advance, and what the app's own suspension
  // stops along with everything else.
  int _quietSweeps = 0;
  // Whether the current socket ever delivered anything at all — the "this
  // connection was working" half of the backoff rule in _stall.
  bool _delivered = false;
  Timer? _sweep;

  RealtimeSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  StreamSubscription<dynamic>? _connectivitySub;
  Timer? _reconnectTimer;
  Completer<bool>? _pongWaiter;
  bool _connecting = false;
  bool _disposed = false;
  // Forces a token refresh on the next connect — set when the server closed
  // us with 4401 (expired/stale token), which the local expiry check alone
  // wouldn't catch for a token revoked early (claims bump, account deletion).
  bool _forceTokenRefresh = false;
  int _failures = 0;
  DateTime? _connectedAt;
  // Whose session this client serves (null = signed out). Compared by uid in
  // onSessionChanged so a token refresh — a new SessionClaims object for the
  // same user — is not mistaken for a login.
  String? _sessionUid;
  // Bumped on every login/logout. A connect that started under one session
  // and completes under another must not attach its socket — it would be
  // authenticated as the previous user.
  int _sessionEpoch = 0;

  static const _pingInterval = Duration(seconds: 20);
  static const _connectTimeout = Duration(seconds: 10);
  static const _pongTimeout = Duration(seconds: 5);
  static const _maxBackoff = Duration(seconds: 30);
  // A connection that lasted at least this long "worked" — its loss resets
  // the backoff so the first retry is immediate. Anything shorter counts as a
  // failed attempt (a server closing us on arrival, a proxy rejecting the
  // upgrade) and backs off, so a hard failure can't turn into a tight loop.
  static const _stableAfter = Duration(seconds: 5);

  /// How long the socket may deliver NOTHING, while at least one subscribe is
  /// outstanding, before it is declared stalled.
  ///
  /// It measures silence, not elapsed time since a subscribe, and that
  /// distinction is the whole rule. An app launch subscribes to ~20 channels
  /// at once (the chat list, each open thread, every visible post — see
  /// gateway.ts), all of whose snapshots serialise over one TCP connection; a
  /// 200-message thread window alone is ~165 KB. On a slow link the last of
  /// those can legitimately be many seconds behind the first. A per-channel
  /// stopwatch started at subscribe time therefore fired on a HEALTHY server
  /// that was simply still sending — and since a stall drops the whole
  /// socket, the reconnect re-requested all ~20 snapshots (plus a REST
  /// re-seed per channel) over the link that was already too slow, and never
  /// converged: "Connecting…" forever on a connection that was working.
  /// Every frame the server delivers resets this clock, so the condition is
  /// now what it always meant to be — the server has stopped delivering.
  ///
  /// Comfortably above the server's own SUBSCRIBE_DEADLINE_MS (10 s,
  /// gateway.ts), so a subscribe the server cannot serve reaches us as its
  /// explicit `SUBSCRIBE_FAILED` — one channel, handled as one channel —
  /// instead of being raced by a client timer that can only drop everything.
  /// Still well under the REST client's own 30 s receiveTimeout budget for
  /// the same data (api_client.dart).
  @visibleForTesting
  static const snapshotDeadline = Duration(seconds: 25);

  /// How often the stall rule is evaluated while connected. Coarse on
  /// purpose: it costs one comparison, and the deadline it enforces is
  /// measured in tens of seconds.
  @visibleForTesting
  static const sweepInterval = Duration(seconds: 5);

  /// Subscribe frames for one channel on one socket before the socket itself
  /// is written off. The first `SUBSCRIBE_FAILED` re-subscribes that channel
  /// alone; a second says the server, not the channel, is the problem.
  static const _maxSubscribeAttempts = 2;

  /// Smallest gap between two `resyncs` announcements for one channel — a
  /// rate limit on the REST re-seed they trigger, not a mute. It cannot starve
  /// the re-seed: a socket that reconnects and then still delivers nothing
  /// needs a full [snapshotDeadline] (25 s, longer than this) to stall again,
  /// so the announcement that matters is always through. What it drops is the
  /// redundant one — a reconnect that DID get its snapshot, where the socket's
  /// own copy is fresher than anything REST could answer, or a flapping
  /// network reconnecting several times a second.
  @visibleForTesting
  static const resyncInterval = Duration(seconds: 10);

  @visibleForTesting
  int get sessionEpoch => _sessionEpoch;

  bool get _wanted => _controllers.isNotEmpty && !_disposed;

  void _setState(RealtimeConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateChanges.isClosed) _stateChanges.add(state);
  }

  Stream<RealtimeEvent> subscribe(String channel) {
    var controller = _controllers[channel];
    if (controller == null || controller.isClosed) {
      controller = _createController(channel);
      _controllers[channel] = controller;
    }
    return controller.stream;
  }

  StreamController<RealtimeEvent> _createController(String channel) {
    late final StreamController<RealtimeEvent> c;
    c = StreamController<RealtimeEvent>.broadcast(
      onListen: () {
        if (_state == RealtimeConnectionState.connected) {
          _sendSubscribe(channel);
          _everSubscribed.add(channel);
          return;
        }
        // A retry is already scheduled (the server is unreachable): let the
        // backoff stand. Every feed card scrolling into view used to cancel
        // it and connect immediately, turning backoff into a connect storm.
        if (_reconnectTimer?.isActive ?? false) return;
        _connectSoon(immediate: true);
      },
      onCancel: () {
        _sendFrame({'type': 'unsubscribe', 'channel': channel});
        _forgetPending(channel);
        _everSubscribed.remove(channel);
        _resyncCooldown.remove(channel)?.cancel();
        if (identical(_controllers[channel], c)) _controllers.remove(channel);
        c.close();
        if (_controllers.isEmpty && !_stateChanges.isClosed) _stateChanges.add(state);
      },
    );
    return c;
  }

  void _connectSoon({bool immediate = false}) {
    if (!_wanted || _connecting || _socket != null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(immediate ? Duration.zero : _backoff(), () {
      unawaited(_connect());
    });
  }

  /// 1 s, 2 s, 4 s … capped at 30 s, each ±50% jitter so a crowd of phones
  /// that lost the same cell tower doesn't reconnect in lockstep.
  Duration _backoff() {
    final base = min(_maxBackoff.inMilliseconds, 1000 * (1 << min(_failures, 5)));
    final jitter = (base * (_random.nextDouble() - 0.5)).round();
    return Duration(milliseconds: base + jitter);
  }

  Future<void> _connect() async {
    if (!_wanted || _connecting || _socket != null) return;
    _connecting = true;
    _setState(RealtimeConnectionState.connecting);
    final epoch = _sessionEpoch;

    var connected = false;
    var noSession = false;
    try {
      final token = await _ref
          .read(accessTokenSourceProvider)
          .validToken(forceRefresh: _forceTokenRefresh);
      _forceTokenRefresh = false;
      if (token == null) {
        // No usable token. "Logged out / refresh token dead" means there is
        // nothing to connect as until onSessionChanged fires on a login. But
        // "have a session, just couldn't refresh it right now" (expired token
        // + refresh endpoint unreachable — a network flicker at exactly the
        // wrong moment) is an ordinary failure to back off from and retry;
        // treating it as no-session left the socket down until the next
        // resume or connectivity change.
        final stored = await _ref.read(secureSessionStoreProvider).readAccessToken();
        noSession = stored == null;
        if (!noSession) _failures++;
      } else {
        final wsBase = apiBaseUrl.replaceFirst('http', 'ws');
        final socket = await _ref.read(realtimeSocketConnectorProvider)(
          Uri.parse('$wsBase/ws?token=$token'),
        );
        if (!_wanted || _disposed || epoch != _sessionEpoch) {
          // Nobody wants it any more, or the session changed underneath us
          // (logout, or a different login) — this socket carries the wrong
          // identity. Drop it; the tail below reconnects if still wanted.
          unawaited(socket.close());
        } else {
          _socket = socket;
          _connectedAt = DateTime.now();
          _quietSweeps = 0;
          _delivered = false;
          _subscribeAttempts.clear();
          _sub = socket.stream.listen(
            _onMessage,
            onDone: () => _onClosed(socket),
            onError: (Object _) => _onClosed(socket),
            cancelOnError: true,
          );
          // Covers both the initial connect and any reconnect after a drop —
          // the server answers each with a fresh snapshot, so state resyncs.
          // A channel that already had a subscribe out on an earlier socket
          // is announced on `resyncs` too (see there).
          for (final name in _controllers.keys) {
            _sendSubscribe(name);
            if (_everSubscribed.add(name)) continue;
            _announceResync(name);
          }
          connected = true;
        }
      }
    } catch (e) {
      // runtimeType only — the exception text can carry the connect URI,
      // and the access token rides in its query string.
      debugPrint('realtime: connect failed: ${e.runtimeType}');
      _failures++;
    }
    _connecting = false;

    if (connected) {
      _setState(RealtimeConnectionState.connected);
    } else {
      _setState(RealtimeConnectionState.disconnected);
      if (epoch != _sessionEpoch) {
        _failures = 0;
        _connectSoon(immediate: true);
      } else if (!noSession) {
        _connectSoon();
      }
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      if (json['type'] == 'pong') {
        _pongWaiter?.complete(true);
        _pongWaiter = null;
        return;
      }
      final channelName = json['channel'] as String?;
      if (channelName == null) return;
      final event = RealtimeEvent.fromJson(json);
      final isError = event.type == RealtimeEventType.error;
      if (!isError) {
        // Any frame the server actually delivered proves it is alive and
        // pushing — for EVERY channel on this socket, not just this one. An
        // error frame deliberately does not count: a server whose bus is down
        // answers every subscribe with SUBSCRIBE_FAILED, and letting that
        // reset the silence clock would make the stall rule unreachable
        // exactly when it is needed. Nor does a `pong`: the socket that
        // started all of this answered pings perfectly while delivering
        // nothing (docs/08_OPERATIONS.md §3a).
        _quietSweeps = 0;
        _delivered = true;
      }
      if (event.type == RealtimeEventType.snapshot || isError) {
        _awaitingSnapshot.remove(channelName);
      }
      // The server's own verdict on a subscribe it could not serve (its bus
      // timed out). Handled per CHANNEL first — re-subscribe just this one —
      // because dropping the whole socket costs every other channel on it a
      // reconnect and a REST re-seed. Only when the same channel fails twice
      // on one socket is the server, rather than the channel, the problem.
      // FORBIDDEN and UNKNOWN_CHANNEL are final and are delivered.
      if (isError && event.error == 'SUBSCRIBE_FAILED') {
        _retryOrStall(channelName, 'subscribe failed');
        return;
      }
      _subscribeAttempts.remove(channelName);
      _controllers[channelName]?.add(event);
    } catch (_) {
      // Malformed frame — never worth crashing the socket listener over.
    }
  }

  void _sendSubscribe(String channel) {
    _sendFrame({'type': 'subscribe', 'channel': channel});
    _awaitingSnapshot.add(channel);
    _subscribeAttempts[channel] = (_subscribeAttempts[channel] ?? 0) + 1;
    _sweep ??= Timer.periodic(sweepInterval, (_) => _checkForSilence());
  }

  void _forgetPending(String channel) {
    _awaitingSnapshot.remove(channel);
    _subscribeAttempts.remove(channel);
  }

  /// Tells this channel's consumers to re-seed over REST, at most once per
  /// [resyncInterval]. See _resyncCooldown for why that limit exists and why
  /// it cannot starve the re-seed.
  void _announceResync(String channel) {
    if (_resyncs.isClosed || _resyncCooldown.containsKey(channel)) return;
    _resyncCooldown[channel] = Timer(resyncInterval, () {
      _resyncCooldown.remove(channel);
    });
    _resyncs.add(channel);
  }

  /// One channel's subscribe went unanswered or came back `SUBSCRIBE_FAILED`.
  /// Re-send that channel's subscribe on the same socket the first time (the
  /// unsubscribe first, because the server may still be holding the previous
  /// attempt's placeholder, against which a bare re-subscribe is a no-op);
  /// escalate to the whole socket on the second.
  void _retryOrStall(String channel, String why) {
    if (!_controllers.containsKey(channel)) {
      _forgetPending(channel);
      return;
    }
    if ((_subscribeAttempts[channel] ?? 0) >= _maxSubscribeAttempts) {
      _stall(channel, why);
      return;
    }
    debugPrint('realtime: $why for $channel — re-subscribing that channel');
    _sendFrame({'type': 'unsubscribe', 'channel': channel});
    _sendSubscribe(channel);
  }

  /// The stall rule, evaluated every [sweepInterval] while connected: at least
  /// one subscribe outstanding and NOTHING delivered on the socket for
  /// [snapshotDeadline]. See snapshotDeadline for why silence rather than
  /// elapsed-since-subscribe.
  void _checkForSilence() {
    if (_socket == null) {
      _sweep?.cancel();
      _sweep = null;
      return;
    }
    // Nothing is waiting on the server, so silence means nothing.
    if (_awaitingSnapshot.isEmpty) {
      _quietSweeps = 0;
      return;
    }
    _quietSweeps++;
    if (_quietSweeps * sweepInterval.inMilliseconds < snapshotDeadline.inMilliseconds) {
      return;
    }
    _stall(
      _awaitingSnapshot.first,
      'nothing delivered in ${snapshotDeadline.inSeconds} s '
      '(${_awaitingSnapshot.length} channel(s) still waiting)',
    );
  }

  /// The socket is open but the server is not delivering (see
  /// RealtimeConnectionState.stalled). Drop it and reconnect through the
  /// normal backoff, and make the consumers re-seed over REST.
  void _stall(String channel, String why) {
    if (_socket == null) return;
    debugPrint('realtime: $why for $channel — reconnecting');
    // The same two-tier rule _onClosed applies to a drop, which a stall used
    // to bypass entirely: _failures was only ever incremented, and because
    // _dropSocket cancels the stream listener first, _onClosed can never run
    // for a stalled socket and apply the rule on its behalf. A connection
    // that had been delivering for an hour was therefore punished like one
    // that never connected — up to ~45 s of "Connecting…" before the first
    // retry, once five lifetime stalls had saturated the backoff.
    //
    // "Worked" means it actually DELIVERED something, not merely that it
    // stayed open for a while: the socket this whole state exists for is one
    // that stays open and answers pings forever. (_onClosed's other half —
    // "lasted longer than _stableAfter" — is implied here: reaching a stall
    // costs a full snapshotDeadline, which is five times that.) 1 rather than
    // 0, so even a was-working socket is retried after ~1–2 s rather than
    // instantly; with a whole deadline spent before every stall, that is a
    // floor, not a loop.
    final worked = _delivered;
    _dropSocket();
    _setState(RealtimeConnectionState.stalled);
    _failures = worked ? 1 : _failures + 1;
    _connectSoon();
  }

  /// Forgets the current socket, closing it if there is one, without waiting
  /// for the close to land: the listener is cancelled first, so its onDone
  /// never reaches _onClosed and cannot count the same loss twice.
  void _dropSocket() {
    final socket = _socket;
    _sweep?.cancel();
    _sweep = null;
    _awaitingSnapshot.clear();
    _subscribeAttempts.clear();
    _quietSweeps = 0;
    _delivered = false;
    _sub?.cancel();
    _sub = null;
    _socket = null;
    _pongWaiter?.complete(false);
    _pongWaiter = null;
    if (socket != null) unawaited(socket.close());
  }

  void _onClosed(RealtimeSocket socket) {
    if (!identical(_socket, socket)) return; // a stale socket's late close
    final code = socket.closeCode;
    debugPrint('realtime: socket closed code=$code reason=${socket.closeReason}');
    _dropSocket();
    _setState(RealtimeConnectionState.disconnected);

    if (code == 4401) _forceTokenRefresh = true;
    final stable = _connectedAt != null && DateTime.now().difference(_connectedAt!) > _stableAfter;
    if (stable) {
      _failures = 0;
    } else {
      _failures++;
    }
    _connectSoon(immediate: stable);
  }

  void _sendFrame(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(jsonEncode(frame));
    } catch (_) {
      // Sink already closing — _onClosed will run and reconnect.
    }
  }

  /// App came to the foreground / network came back. The socket we hold may
  /// be dead without having said so (iOS suspends sockets silently; Android
  /// Doze drops them). Probe it, and reconnect right away if it doesn't
  /// answer — this is what makes messages sent while the phone was in a
  /// pocket appear as the screen turns on, not a ping-interval later.
  Future<void> checkConnection() async {
    if (_disposed) return;
    final socket = _socket;
    if (socket == null) {
      _failures = 0;
      _connectSoon(immediate: true);
      return;
    }
    if (_pongWaiter != null) return; // a probe is already in flight
    final waiter = _pongWaiter = Completer<bool>();
    _sendFrame({'type': 'ping'});
    final alive = await waiter.future.timeout(_pongTimeout, onTimeout: () => false);
    if (identical(_pongWaiter, waiter)) _pongWaiter = null;
    if (alive || !identical(_socket, socket)) return;

    debugPrint('realtime: socket unresponsive after resume — reconnecting');
    _dropSocket();
    _setState(RealtimeConnectionState.disconnected);
    _failures = 0;
    _connectSoon(immediate: true);
  }

  /// Login/logout. The socket authenticates once, at connect, so a different
  /// user needs a different socket. A token refresh for the SAME user also
  /// lands here (the session state is replaced on every refresh) and is a
  /// no-op whether or not a socket exists: a live socket stays valid (the
  /// server never re-checks expiry on an open connection), and a connect in
  /// flight must not be restarted. That second half is what an earlier guard
  /// got wrong by comparing against the uid of the ATTACHED socket, known
  /// only after the handshake: _connect itself refreshes the token before
  /// opening the socket (validToken), so every connect that refreshed bumped
  /// the epoch, discarded the socket it had just opened and reconnected —
  /// one wasted handshake per reconnect at the production TTL, and with a
  /// TTL under the refresh margin a loop of ~600 refreshes in 6 s until the
  /// rate limiter ended it (docs/08_OPERATIONS.md §3a).
  void onSessionChanged(String? uid) {
    if (uid != null && uid == _sessionUid) return;
    _sessionUid = uid;
    _sessionEpoch++;
    if (uid == null) {
      _closeSocket();
      return;
    }
    if (_socket != null) _closeSocket();
    _failures = 0;
    _forceTokenRefresh = false;
    // If a connect is in flight it sees the epoch change and reconnects
    // itself; otherwise start one now.
    if (!_connecting) _connectSoon(immediate: true);
  }

  void _closeSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _dropSocket();
    _setState(RealtimeConnectionState.disconnected);
  }

  void dispose() {
    _disposed = true;
    _connectivitySub?.cancel();
    _closeSocket();
    for (final timer in _resyncCooldown.values) {
      timer.cancel();
    }
    _resyncCooldown.clear();
    _stateChanges.close();
    _resyncs.close();
  }
}

final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  // Seeded with whoever is already signed in: ref.listen reports changes
  // only, and without the seed the first token refresh of a stored session
  // would read as a login (see onSessionChanged).
  final client = RealtimeClient(
    ref,
    sessionUid: ref.read(sessionControllerProvider).value?.uid,
  );
  ref.listen(sessionControllerProvider, (previous, next) {
    client.onSessionChanged(next.value?.uid);
  });
  ref.onDispose(client.dispose);
  return client;
});

/// Live connection state for the UI ("Connecting…" captions). Emits the
/// current state immediately so a widget never waits on the first change.
final realtimeConnectionProvider = StreamProvider<RealtimeConnectionState>((ref) async* {
  final client = ref.watch(realtimeClientProvider);
  yield client.state;
  yield* client.stateChanges;
});

/// True when the socket is down — or open but not delivering (`stalled`) —
/// while something needs it: the condition the "Connecting…" captions key
/// on. `idle` (nothing subscribed) is not a problem.
bool realtimeNeedsAttention(RealtimeConnectionState? state) =>
    state == RealtimeConnectionState.disconnected ||
    state == RealtimeConnectionState.connecting ||
    state == RealtimeConnectionState.stalled;
