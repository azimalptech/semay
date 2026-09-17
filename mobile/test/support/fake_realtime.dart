// Stand-ins for the platform-backed pieces around RealtimeClient, so the
// real client, the real chat providers and the real thread screen can be
// driven in a widget test with nothing but Dart: a scripted socket the test
// feeds frames into, an in-memory session store and chat cache, and an inert
// connectivity channel. Mirrors the harness that reproduced the dead-bus
// report against a live server (docs/08_OPERATIONS.md §3a).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/chat_cache.dart';
import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/session.dart';

/// An unsigned JWT the client can decode (it never verifies signatures):
/// [uid], issued now, valid for [ttl].
String fakeJwt(String uid, {Duration ttl = const Duration(minutes: 15)}) {
  String seg(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final header = seg({'alg': 'HS256', 'typ': 'JWT'});
  final payload = seg({
    'sub': uid,
    'role': 'user',
    'storeIds': <String>[],
    'claimsVersion': 0,
    'iat': now,
    'exp': now + ttl.inSeconds,
  });
  return '$header.$payload.sig';
}

/// The server end of one socket: records every frame the client sends,
/// answers app-level pings, and delivers whatever the test hands it.
/// Never sends a snapshot on its own — that silence is the condition under
/// test.
class FakeSocket implements RealtimeSocket {
  final _out = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  @override
  Stream<dynamic> get stream => _out.stream;

  @override
  void send(String frame) {
    final json = jsonDecode(frame) as Map<String, dynamic>;
    sent.add(json);
    if (json['type'] == 'ping') deliver({'type': 'pong'});
  }

  void deliver(Map<String, dynamic> frame) {
    if (!_out.isClosed) _out.add(jsonEncode(frame));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }

  @override
  int? get closeCode => closed ? 1000 : null;

  @override
  String? get closeReason => null;

  List<String> get subscribed => sent
      .where((f) => f['type'] == 'subscribe')
      .map((f) => f['channel'] as String)
      .toList();
}

/// A connector that hands out [FakeSocket]s and remembers them in order, so
/// a test can tell a reconnect (a second socket) from the first connect.
class FakeConnector {
  final sockets = <FakeSocket>[];

  Future<RealtimeSocket> call(Uri uri) async {
    final socket = FakeSocket();
    sockets.add(socket);
    return socket;
  }
}

class MemSessionStore implements SecureSessionStore {
  MemSessionStore({String? accessToken, String? refreshToken})
    : _access = accessToken,
      _refresh = refreshToken;

  String? _access;
  String? _refresh;

  @override
  Future<String?> readAccessToken() async => _access;
  @override
  Future<String?> readRefreshToken() async => _refresh;
  @override
  Future<void> save({required String accessToken, required String refreshToken}) async {
    _refresh = refreshToken;
    _access = accessToken;
  }

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }
}

class MemChatCache extends ChatCache {
  MemChatCache({String? ownerUid = 'u1'}) : super(ownerUid: () => ownerUid);

  final _chats = <String, Map<String, dynamic>>{};
  final _messages = <String, Map<int, Map<String, dynamic>>>{};

  @override
  Future<List<Map<String, dynamic>>> chats() async => _chats.values.toList();
  @override
  Future<Map<String, dynamic>?> chat(String id) async => _chats[id];
  @override
  Future<void> replaceChats(Iterable<Map<String, dynamic>> rows, {String? storeId}) async {
    if (storeId == null) {
      _chats.clear();
    } else {
      _chats.removeWhere((_, c) => c['storeId'] == storeId);
    }
    for (final c in rows) {
      _chats[c['id'] as String] = c;
    }
  }

  @override
  Future<void> upsertChat(Map<String, dynamic> chat) async =>
      _chats[chat['id'] as String] = chat;
  @override
  Future<void> removeChat(String id) async => _chats.remove(id);
  @override
  Future<List<Map<String, dynamic>>> messages(String chatId) async {
    final m = _messages[chatId];
    if (m == null) return const [];
    final keys = m.keys.toList()..sort();
    return keys.map((k) => m[k]!).toList();
  }

  @override
  Future<void> upsertMessages(String chatId, Iterable<Map<String, dynamic>> rows) async {
    final m = _messages.putIfAbsent(chatId, () => {});
    for (final r in rows) {
      final id = int.tryParse('${r['id']}');
      if (id != null) m[id] = r;
    }
  }

  @override
  Future<void> removeMessage(String chatId, String id) async =>
      _messages[chatId]?.remove(int.tryParse(id));
  @override
  Future<void> clearMessages(String chatId) async => _messages.remove(chatId);
  @override
  Future<void> pruneMessagesUpTo(String chatId, int cutoffId) async =>
      _messages[chatId]?.removeWhere((k, _) => k <= cutoffId);
  @override
  Future<void> clear() async {
    _chats.clear();
    _messages.clear();
  }

  @override
  void dispose() {}
}

/// connectivity_plus has no platform side under flutter_tester: makes its
/// channels inert so RealtimeClient's constructor subscription is harmless.
void stubConnectivity() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
    MockStreamHandler.inline(onListen: (_, _) {}, onCancel: (_) {}),
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (call) async => <String>['wifi'],
  );
}
