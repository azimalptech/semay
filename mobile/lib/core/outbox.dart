import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';

/// Offline write outbox (Phase 9b). A durable local SQLite queue for the two
/// mutations users most expect to survive bad signal — chat messages and
/// like/save toggles — measured at 9s–14min real latency this project. Each
/// queued item carries a client-generated idempotency key so a retried replay
/// can't double-send (the server dedupes; see server clientKey + the
/// naturally-idempotent like/save PKs). Applied optimistically in the UI
/// immediately; drained on reconnect / app-resume with backoff.
enum OutboxKind { message, like, unlike, save, unsave }

class OutboxItem {
  OutboxItem({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    required this.attempts,
  });

  final String id; // == clientKey for messages
  final OutboxKind kind;
  final Map<String, dynamic> payload;
  final int createdAt;
  final int attempts;

  static OutboxKind _parseKind(String s) =>
      OutboxKind.values.firstWhere((k) => k.name == s);

  factory OutboxItem.fromRow(Map<String, dynamic> row) => OutboxItem(
    id: row['id'] as String,
    kind: _parseKind(row['kind'] as String),
    payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
    createdAt: row['created_at'] as int,
    attempts: row['attempts'] as int,
  );
}

class OutboxService {
  OutboxService(this._api, this._connectivity);

  final ApiClient _api;
  final Connectivity _connectivity;
  final _uuid = const Uuid();

  Database? _db;
  bool _draining = false;
  StreamSubscription<dynamic>? _connSub;

  /// Fires on every enqueue/drain so `pendingMessagesProvider` can re-query the
  /// optimistic view. Broadcast so multiple open chats can each listen.
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _bump() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'semay_outbox.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE outbox(
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0
        )
      '''),
    );
    return _db!;
  }

  /// Starts the drain-on-reconnect loop. Call once at app start.
  Future<void> start() async {
    await _open();
    _connSub = _connectivity.onConnectivityChanged.listen((_) => drain());
    unawaited(drain());
  }

  void dispose() {
    _connSub?.cancel();
    _changes.close();
    _db?.close();
  }

  String newKey() => _uuid.v4();

  Future<void> enqueue(OutboxKind kind, Map<String, dynamic> payload, {String? id}) async {
    final db = await _open();
    await db.insert('outbox', {
      'id': id ?? newKey(),
      'kind': kind.name,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _bump();
    unawaited(drain());
  }

  /// Pending message items for a chat (optimistic "sending…" bubbles), oldest
  /// first. Cheap synchronous-ish read for the UI merge.
  Future<List<OutboxItem>> pendingMessages(String chatId) async {
    final db = await _open();
    final rows = await db.query(
      'outbox',
      where: 'kind = ?',
      whereArgs: [OutboxKind.message.name],
      orderBy: 'created_at ASC',
    );
    return rows
        .map(OutboxItem.fromRow)
        .where((i) => i.payload['chatId'] == chatId)
        .toList();
  }

  Future<void> _remove(String id) async {
    final db = await _open();
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _bumpAttempts(String id, int attempts) async {
    final db = await _open();
    await db.update('outbox', {'attempts': attempts}, where: 'id = ?', whereArgs: [id]);
  }

  /// Drains the queue oldest-first. Stops on the first network failure (offline
  /// again — retry on next reconnect). Drops an item on a permanent 4xx
  /// (validation/authz/not-found) so a poison item can't wedge the queue.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final db = await _open();
      while (true) {
        final rows = await db.query('outbox', orderBy: 'created_at ASC', limit: 1);
        if (rows.isEmpty) break;
        final item = OutboxItem.fromRow(rows.first);
        try {
          await _send(item);
          await _remove(item.id);
          _bump();
        } on ApiException catch (e) {
          final status = e.statusCode ?? 0;
          // 4xx (except 401, which the ApiClient interceptor already tried to
          // refresh) is permanent — drop it rather than retry forever.
          if (status >= 400 && status < 500 && status != 401) {
            await _remove(item.id);
            _bump();
            continue;
          }
          // 401 after refresh failed, or 5xx — treat as retryable; bump the
          // attempt count and stop the drain (retry on next trigger).
          await _bumpAttempts(item.id, item.attempts + 1);
          break;
        } catch (_) {
          // Network/timeout — offline again. Retry on next reconnect.
          await _bumpAttempts(item.id, item.attempts + 1);
          break;
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _send(OutboxItem item) async {
    final pl = item.payload;
    switch (item.kind) {
      case OutboxKind.message:
        await _api.post('/chats/${pl['chatId']}/messages', body: {
          ...Map<String, dynamic>.from(pl)..remove('chatId'),
          'clientKey': item.id,
        });
      case OutboxKind.like:
        await _api.post('/posts/${pl['postId']}/like');
      case OutboxKind.unlike:
        await _api.delete('/posts/${pl['postId']}/like');
      case OutboxKind.save:
        await _api.post('/posts/${pl['postId']}/save');
      case OutboxKind.unsave:
        await _api.delete('/posts/${pl['postId']}/save');
    }
  }
}

final outboxServiceProvider = Provider<OutboxService>((ref) {
  final service = OutboxService(ref.watch(apiClientProvider), Connectivity());
  ref.onDispose(service.dispose);
  return service;
});

/// Optimistic pending messages for a chat — re-queried on every outbox change
/// (enqueue/drain), so a message sent offline shows as a "sending…" bubble
/// immediately and disappears once the real one echoes back over the channel.
final pendingMessagesProvider =
    StreamProvider.family<List<OutboxItem>, String>((ref, chatId) async* {
      final outbox = ref.watch(outboxServiceProvider);
      yield await outbox.pendingMessages(chatId);
      await for (final _ in outbox.changes) {
        yield await outbox.pendingMessages(chatId);
      }
    }, isAutoDispose: true);
