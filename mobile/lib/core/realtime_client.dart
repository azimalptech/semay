import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'session.dart';

enum RealtimeEventType { snapshot, upsert, remove, error }

/// One frame off the multiplexed WS connection — see docs/07_MIGRATION.md's
/// realtime gateway section. `snapshot` always arrives first after a
/// subscribe (current state, same role Firestore's first listener emission
/// played); `upsert`/`remove` are incremental diffs after that.
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
      default:
        return RealtimeEvent(type: RealtimeEventType.error, error: json['error'] as String?);
    }
  }
}

/// One WS connection, ref-counted per channel. `subscribe(channel)` sends a
/// `subscribe` frame on the first listener and `unsubscribe` when the last
/// one cancels — wrapping this in `StreamProvider.family(..., isAutoDispose:
/// true)` (see e.g. chat_providers.dart) makes Riverpod's own autoDispose
/// transparently become the real WS unsubscribe, reproducing Firestore's
/// per-listener economics exactly (this is the design the approved plan
/// calls out as the highest-risk piece of the whole migration).
class RealtimeClient {
  RealtimeClient(this._ref);

  final Ref _ref;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Future<void>? _connectFuture;

  final Map<String, StreamController<RealtimeEvent>> _controllers = {};

  Future<void> _ensureConnected() {
    return _connectFuture ??= _doConnect().whenComplete(() => _connectFuture = null);
  }

  Future<void> _doConnect() async {
    final token = await _ref.read(secureSessionStoreProvider).readAccessToken();
    if (token == null) return;

    final wsBase = apiBaseUrl.replaceFirst('http', 'ws');
    final uri = Uri.parse('$wsBase/ws?token=$token');
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;

    _channel = channel;
    _sub = channel.stream.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (Object _) => _onDisconnect(),
    );
    // Covers both the initial connect and any reconnect after a drop.
    for (final channelName in _controllers.keys) {
      _sendFrame('subscribe', channelName);
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final channelName = json['channel'] as String?;
      if (channelName == null) return;
      _controllers[channelName]?.add(RealtimeEvent.fromJson(json));
    } catch (_) {
      // Malformed frame — never worth crashing the socket listener over.
    }
  }

  void _onDisconnect() {
    _sub?.cancel();
    _channel = null;
    _sub = null;
    if (_controllers.isNotEmpty) {
      Future.delayed(const Duration(seconds: 2), _ensureConnected);
    }
  }

  void _sendFrame(String type, String channel) {
    _channel?.sink.add(jsonEncode({'type': type, 'channel': channel}));
  }

  Stream<RealtimeEvent> subscribe(String channel) {
    final controller = _controllers.putIfAbsent(channel, () {
      late final StreamController<RealtimeEvent> c;
      c = StreamController<RealtimeEvent>.broadcast(
        onListen: () => _ensureConnected().then((_) => _sendFrame('subscribe', channel)),
        onCancel: () {
          _sendFrame('unsubscribe', channel);
          _controllers.remove(channel);
          c.close();
        },
      );
      return c;
    });
    return controller.stream;
  }

  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
  }
}

final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  final client = RealtimeClient(ref);
  ref.onDispose(client.dispose);
  return client;
});
