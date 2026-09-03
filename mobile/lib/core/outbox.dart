import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'session.dart';

/// Offline write outbox (Phase 9b). A durable local SQLite queue for the two
/// mutations users most expect to survive bad signal — chat messages and
/// like/save toggles — measured at 9s–14min real latency this project. Each
/// queued item carries a client-generated idempotency key so a retried replay
/// can't double-send (the server dedupes; see server clientKey + the
/// naturally-idempotent like/save PKs). Applied optimistically in the UI
/// immediately; drained on reconnect / app-resume with backoff.
enum OutboxKind { message, like, unlike, save, unsave }

/// Attempts after which a pending message is shown as "not sent" (red mark,
/// tap to retry) instead of the sending clock. It keeps being retried in the
/// background either way — this is only about being honest in the UI once a
/// send has clearly not gone through in ~15 s, the way Instagram flags it,
/// rather than showing a clock forever.
const outboxFailedAfterAttempts = 3;

/// Uploads one media file and returns its public URL — PostsService.uploadMedia
/// behind a function, because PostsService itself depends on the outbox (for
/// like/save) and the outbox must not depend back on it at construction.
typedef MediaUploader = Future<String> Function({
  required String folder,
  required Uint8List bytes,
  required String fileExt,
  required String contentType,
});

class OutboxItem {
  OutboxItem({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    required this.attempts,
    this.blockedByAttempts = 0,
  });

  final String id; // == clientKey for messages
  final OutboxKind kind;
  final Map<String, dynamic> payload;
  final int createdAt;
  final int attempts;

  /// Attempts accrued by the item at the HEAD of the queue. The queue drains
  /// strictly oldest-first and stops at the first failure, so only the head
  /// ever fails — everything queued behind it is stuck just as hard, and must
  /// show it (otherwise only the oldest of several unsent messages turned
  /// red while the rest showed a clock forever).
  final int blockedByAttempts;

  bool get looksFailed => max(attempts, blockedByAttempts) >= outboxFailedAfterAttempts;

  static OutboxKind _parseKind(String s) =>
      OutboxKind.values.firstWhere((k) => k.name == s);

  factory OutboxItem.fromRow(Map<String, dynamic> row, {int blockedByAttempts = 0}) => OutboxItem(
    id: row['id'] as String,
    kind: _parseKind(row['kind'] as String),
    payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
    createdAt: row['created_at'] as int,
    attempts: row['attempts'] as int,
    blockedByAttempts: blockedByAttempts,
  );
}

/// A message the server just accepted, with the row it created. Emitted so
/// the open thread can show the real message the instant the POST returns —
/// previously it waited for the server's echo over the WebSocket, and if the
/// socket happened to be down the optimistic bubble was removed (the outbox
/// item was done) while the echo never came: the user watched their own
/// message vanish until the next snapshot.
class SentMessage {
  const SentMessage({required this.chatId, required this.message});

  final String chatId;
  final Map<String, dynamic> message;
}

/// An item that can never succeed (its media file is gone) — dropped rather
/// than retried forever, like a 4xx.
class _PermanentSendError implements Exception {
  const _PermanentSendError(this.reason);
  final String reason;
}

class OutboxService {
  OutboxService(
    this._api,
    this._connectivity, {
    required bool Function() hasSession,
    required MediaUploader uploader,
  }) : _hasSession = hasSession,
       _uploader = uploader;

  final ApiClient _api;
  final Connectivity _connectivity;
  // Whether there is a signed-in session right now. Nothing drains without
  // one: a logged-out device used to keep POSTing every ~30 s with no token,
  // and rows queued by the previous user would have gone out under whoever
  // logged in next (see clear()).
  final bool Function() _hasSession;
  final MediaUploader _uploader;
  final _uuid = const Uuid();
  final _random = Random();

  Database? _db;
  bool _draining = false;
  // A drain trigger (connectivity, resume, enqueue, retry) that lands while a
  // drain is already running is remembered and honoured as soon as the
  // current one settles, instead of being dropped — a hung POST used to
  // swallow every trigger for its whole 15–30 s timeout.
  bool _drainRequested = false;
  StreamSubscription<dynamic>? _connSub;
  Timer? _retryTimer;

  /// Fires on every enqueue/drain so `pendingMessagesProvider` can re-query the
  /// optimistic view. Broadcast so multiple open chats can each listen.
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _bump() {
    if (!_changes.isClosed) _changes.add(null);
  }

  final StreamController<SentMessage> _sent = StreamController<SentMessage>.broadcast();
  Stream<SentMessage> get sentMessages => _sent.stream;

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
    _retryTimer?.cancel();
    _changes.close();
    _sent.close();
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
    final head = await db.query('outbox', columns: ['attempts'], orderBy: 'created_at ASC', limit: 1);
    final headAttempts = head.isEmpty ? 0 : head.first['attempts'] as int;
    final rows = await db.query(
      'outbox',
      where: 'kind = ?',
      whereArgs: [OutboxKind.message.name],
      orderBy: 'created_at ASC',
    );
    return rows
        .map((r) => OutboxItem.fromRow(r, blockedByAttempts: headAttempts))
        .where((i) => i.payload['chatId'] == chatId)
        .toList();
  }

  /// User tapped a "not sent" bubble: back to the sending clock and try now,
  /// ahead of whatever the backoff timer had planned. If a drain is mid-flight
  /// the request is queued behind it (drain re-loops), not lost.
  Future<void> retry(String id) async {
    final db = await _open();
    await db.update('outbox', {'attempts': 0}, where: 'id = ?', whereArgs: [id]);
    _bump();
    unawaited(drain());
  }

  /// Logout: whatever is queued belongs to the session that just ended and
  /// must never go out under the next one. Queued media files go with it.
  Future<void> clear() async {
    _retryTimer?.cancel();
    final db = await _open();
    final rows = await db.query('outbox', columns: ['payload']);
    for (final r in rows) {
      final pl = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
      await _deleteLocalMedia(pl);
    }
    await db.delete('outbox');
    _bump();
  }

  Future<void> _remove(String id, {Map<String, dynamic>? payload}) async {
    final db = await _open();
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
    if (payload != null) await _deleteLocalMedia(payload);
  }

  Future<void> _updatePayload(String id, Map<String, dynamic> payload) async {
    final db = await _open();
    await db.update('outbox', {'payload': jsonEncode(payload)}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _deleteLocalMedia(Map<String, dynamic> payload) async {
    final path = payload['localMediaPath'] as String?;
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      /* best-effort */
    }
  }

  /// Atomic `attempts + 1` on the row itself, and returns the new value —
  /// rather than writing back a snapshot taken before the request, which
  /// clobbered a retry()'s reset to 0 that landed while the request was in
  /// flight.
  Future<int> _incrementAttempts(String id) async {
    final db = await _open();
    await db.rawUpdate('UPDATE outbox SET attempts = attempts + 1 WHERE id = ?', [id]);
    final rows = await db.query('outbox', columns: ['attempts'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? 0 : rows.first['attempts'] as int;
  }

  /// A failed drain used to wait for the next connectivity change or the next
  /// enqueue — a 5xx or a timeout while ONLINE (nothing changes, nothing new
  /// is sent) left the message sitting there indefinitely. Now it retries on
  /// its own: 2 s, 4 s, 8 s, 16 s, then every ~30 s, with jitter.
  /// [failures] is how many times the head item has now failed (≥ 1).
  void _scheduleRetry(int failures) {
    _retryTimer?.cancel();
    final base = min(30000, 2000 * (1 << min(max(failures - 1, 0), 4)));
    _retryTimer = Timer(
      Duration(milliseconds: base + _random.nextInt(1000)),
      () => unawaited(drain()),
    );
  }

  /// Drains the queue oldest-first. Stops on the first network failure (offline
  /// again — retry on next reconnect). Drops an item on a permanent 4xx
  /// (validation/authz/not-found) so a poison item can't wedge the queue.
  Future<void> drain() async {
    if (_draining) {
      _drainRequested = true;
      return;
    }
    if (!_hasSession()) return;
    _draining = true;
    _drainRequested = false;
    _retryTimer?.cancel();
    try {
      final db = await _open();
      while (true) {
        if (!_hasSession()) break;
        final rows = await db.query('outbox', orderBy: 'created_at ASC', limit: 1);
        if (rows.isEmpty) break;
        final item = OutboxItem.fromRow(rows.first);
        try {
          await _send(item);
          await _remove(item.id, payload: item.payload);
          _bump();
        } on _PermanentSendError catch (e) {
          debugPrint('outbox: dropping ${item.id}: ${e.reason}');
          await _remove(item.id, payload: item.payload);
          _bump();
          continue;
        } on ApiException catch (e) {
          final status = e.statusCode ?? 0;
          // 4xx (except 401, which the ApiClient interceptor already tried to
          // refresh) is permanent — drop it rather than retry forever.
          if (status >= 400 && status < 500 && status != 401) {
            await _remove(item.id, payload: item.payload);
            _bump();
            continue;
          }
          // 401 after refresh failed, or 5xx — treat as retryable; bump the
          // attempt count and stop the drain (retry on next trigger).
          final failures = await _incrementAttempts(item.id);
          _bump();
          _scheduleRetry(failures);
          break;
        } catch (_) {
          // Network/timeout — offline again. Retry on next reconnect.
          final failures = await _incrementAttempts(item.id);
          _bump();
          _scheduleRetry(failures);
          break;
        }
      }
    } finally {
      _draining = false;
      if (_drainRequested) {
        _drainRequested = false;
        unawaited(drain());
      }
    }
  }

  Future<void> _send(OutboxItem item) async {
    final pl = item.payload;
    switch (item.kind) {
      case OutboxKind.message:
        // A media message carries the LOCAL file until it is uploaded; the
        // upload is a step of the send, with the same retry as the send
        // itself. The URL is written back to the row the moment it exists,
        // so a retry after a crash (or after the POST failed) never uploads
        // the same bytes twice.
        final localPath = pl['localMediaPath'] as String?;
        if (localPath != null && pl['mediaUrl'] == null) {
          final file = File(localPath);
          if (!await file.exists()) {
            throw const _PermanentSendError('media file is gone');
          }
          final isVideo = pl['mediaType'] == 'video';
          final url = await _uploader(
            folder: 'chats',
            bytes: await file.readAsBytes(),
            fileExt: isVideo ? 'mp4' : 'jpg',
            contentType: isVideo ? 'video/mp4' : 'image/jpeg',
          );
          pl['mediaUrl'] = url;
          await _updatePayload(item.id, pl);
          _bump(); // the pending bubble switches from local file to URL
        }
        final json = await _api.post('/chats/${pl['chatId']}/messages', body: {
          ...Map<String, dynamic>.from(pl)
            ..remove('chatId')
            ..remove('localMediaPath'),
          'clientKey': item.id,
        });
        final message = json['message'];
        if (message is Map<String, dynamic> && !_sent.isClosed) {
          _sent.add(SentMessage(chatId: pl['chatId'] as String, message: message));
        }
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

/// Wired in main.dart: `uploader` is PostsService.uploadMedia read lazily
/// (PostsService depends on this service, so it cannot be a build-time
/// dependency here — see MediaUploader).
final outboxUploaderProvider = Provider<MediaUploader>((ref) {
  throw UnimplementedError('outboxUploaderProvider must be overridden in main.dart');
});

final outboxServiceProvider = Provider<OutboxService>((ref) {
  final service = OutboxService(
    ref.watch(apiClientProvider),
    Connectivity(),
    hasSession: () => ref.read(sessionControllerProvider).value != null,
    uploader: ({required folder, required bytes, required fileExt, required contentType}) =>
        ref.read(outboxUploaderProvider)(
          folder: folder,
          bytes: bytes,
          fileExt: fileExt,
          contentType: contentType,
        ),
  );
  // Logout empties the queue; a (re)login drains whatever was queued while
  // the session was still resolving at startup.
  ref.listen(sessionControllerProvider, (previous, next) {
    final had = previous?.value != null;
    final has = next.value != null;
    if (had && !has) unawaited(service.clear());
    if (!had && has) unawaited(service.drain());
  });
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
