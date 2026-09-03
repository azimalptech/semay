import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
enum RealtimeConnectionState { idle, disconnected, connecting, connected }

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
///    identity and being refused.
class RealtimeClient {
  RealtimeClient(this._ref) {
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
      _controllers.isEmpty && _state == RealtimeConnectionState.disconnected
      ? RealtimeConnectionState.idle
      : _state;
  Stream<RealtimeConnectionState> get stateChanges => _stateChanges.stream;

  IOWebSocketChannel? _channel;
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
  String? _connectedUid;
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
          _sendFrame({'type': 'subscribe', 'channel': channel});
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
        if (identical(_controllers[channel], c)) _controllers.remove(channel);
        c.close();
        if (_controllers.isEmpty && !_stateChanges.isClosed) _stateChanges.add(state);
      },
    );
    return c;
  }

  void _connectSoon({bool immediate = false}) {
    if (!_wanted || _connecting || _channel != null) return;
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
    if (!_wanted || _connecting || _channel != null) return;
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
        final channel = IOWebSocketChannel.connect(
          Uri.parse('$wsBase/ws?token=$token'),
          // dart:io's own heartbeat: a ping every interval, and if the peer
          // hasn't answered by the next one the socket is closed for us —
          // which lands in _onClosed below and reconnects.
          pingInterval: _pingInterval,
          connectTimeout: _connectTimeout,
        );
        await channel.ready;
        if (!_wanted || _disposed || epoch != _sessionEpoch) {
          // Nobody wants it any more, or the session changed underneath us
          // (logout, or a different login) — this socket carries the wrong
          // identity. Drop it; the tail below reconnects if still wanted.
          unawaited(channel.sink.close());
        } else {
          _channel = channel;
          _connectedUid = SessionClaims.tryDecode(token)?.uid;
          _connectedAt = DateTime.now();
          _sub = channel.stream.listen(
            _onMessage,
            onDone: () => _onClosed(channel),
            onError: (Object _) => _onClosed(channel),
            cancelOnError: true,
          );
          // Covers both the initial connect and any reconnect after a drop —
          // the server answers each with a fresh snapshot, so state resyncs.
          for (final name in _controllers.keys) {
            _sendFrame({'type': 'subscribe', 'channel': name});
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
      _controllers[channelName]?.add(RealtimeEvent.fromJson(json));
    } catch (_) {
      // Malformed frame — never worth crashing the socket listener over.
    }
  }

  void _onClosed(WebSocketChannel channel) {
    if (!identical(_channel, channel)) return; // a stale socket's late close
    final code = channel.closeCode;
    debugPrint('realtime: socket closed code=$code reason=${channel.closeReason}');
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _pongWaiter?.complete(false);
    _pongWaiter = null;
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
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(frame));
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
    final channel = _channel;
    if (channel == null) {
      _failures = 0;
      _connectSoon(immediate: true);
      return;
    }
    if (_pongWaiter != null) return; // a probe is already in flight
    final waiter = _pongWaiter = Completer<bool>();
    _sendFrame({'type': 'ping'});
    final alive = await waiter.future.timeout(_pongTimeout, onTimeout: () => false);
    if (identical(_pongWaiter, waiter)) _pongWaiter = null;
    if (alive || !identical(_channel, channel)) return;

    debugPrint('realtime: socket unresponsive after resume — reconnecting');
    _sub?.cancel();
    _sub = null;
    _channel = null;
    unawaited(channel.sink.close());
    _setState(RealtimeConnectionState.disconnected);
    _failures = 0;
    _connectSoon(immediate: true);
  }

  /// Login/logout. The socket authenticates once, at connect, so a different
  /// user needs a different socket. A token refresh for the SAME user (which
  /// also flows through here) is deliberately a no-op — the live socket stays
  /// valid; the server never re-checks expiry on an open connection.
  void onSessionChanged(String? uid) {
    if (_channel != null && uid != null && uid == _connectedUid) return;
    _sessionEpoch++;
    if (uid == null) {
      _closeSocket();
      _connectedUid = null;
      return;
    }
    if (_channel != null) _closeSocket();
    _failures = 0;
    _forceTokenRefresh = false;
    // If a connect is in flight it sees the epoch change and reconnects
    // itself; otherwise start one now.
    if (!_connecting) _connectSoon(immediate: true);
  }

  void _closeSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final channel = _channel;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _pongWaiter?.complete(false);
    _pongWaiter = null;
    if (channel != null) unawaited(channel.sink.close());
    _setState(RealtimeConnectionState.disconnected);
  }

  void dispose() {
    _disposed = true;
    _connectivitySub?.cancel();
    _closeSocket();
    _stateChanges.close();
  }
}

final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  final client = RealtimeClient(ref);
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

/// True when the socket is down while something needs it — the condition the
/// "Connecting…" captions key on. `idle` (nothing subscribed) is not a problem.
bool realtimeNeedsAttention(RealtimeConnectionState? state) =>
    state == RealtimeConnectionState.disconnected || state == RealtimeConnectionState.connecting;
