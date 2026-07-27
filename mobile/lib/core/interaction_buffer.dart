import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'api_client.dart';

/// The three increment-only engagement signals buffered locally before being
/// flushed to the server in one batch. Likes/saves are NOT here — they're
/// per-user toggles and go through the offline outbox instead (see
/// PostsService.toggleLike / outbox.dart).
enum InteractionKind { view, sent, share }

/// Local view/send/share buffer. Two jobs, both moved off the server on purpose:
///
///  1. **Re-count window** — the same user counting the same post's view/send/
///     share is deduped for a 30-minute window, then allowed to count again.
///     Instead of a per-user row + timestamp on the server (the old once-ever
///     PostView/PostSent/PostShare model), the window is simply "one row per
///     (post, kind) until the next successful flush clears it": a repeat tap in
///     the same window is an INSERT-OR-IGNORE no-op, and the ~30-minute flush
///     both sends the counts AND resets the window ("re-count after sending to
///     server", per the product decision).
///  2. **Batching** — nothing hits the network per tap. Taps accumulate in
///     SQLite (durable across app kills) and flush every ~30 minutes, on app
///     background, and once at startup (to drain whatever the last session left
///     un-sent). A failed flush keeps the rows for the next attempt, so the
///     window only resets once the server has actually received the counts.
class InteractionBuffer {
  InteractionBuffer(this._api);

  final ApiClient _api;

  static const flushInterval = Duration(minutes: 30);

  Database? _db;
  Timer? _timer;
  bool _flushing = false;

  /// Fires on every record/flush so the optimistic on-screen counters
  /// (pendingInteractionsProvider) re-query. Broadcast — many cards may listen.
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _bump() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'semay_interaction_buffer.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE interaction_pending(
          post_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (post_id, kind)
        )
      '''),
    );
    return _db!;
  }

  /// Call once at app start. Drains anything left from the previous session,
  /// then flushes on a fixed cadence. The window (dedup) and the flush share
  /// the same interval by design — a flush is what re-opens counting.
  Future<void> start() async {
    await _open();
    _timer = Timer.periodic(flushInterval, (_) => flush());
    await flush();
  }

  void dispose() {
    _timer?.cancel();
    _changes.close();
    _db?.close();
  }

  /// Records one engagement tap. A repeat for the same (post, kind) inside the
  /// current window is ignored (that's the re-count dedup); it starts counting
  /// again only after the next successful flush clears the row.
  Future<void> record(String postId, InteractionKind kind) async {
    final db = await _open();
    await db.insert(
      'interaction_pending',
      {
        'post_id': postId,
        'kind': kind.name,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      // IGNORE (not replace) so a repeat tap doesn't refresh created_at or
      // re-count — the first tap of the window is the one that counts.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _bump();
  }

  /// This session's not-yet-flushed counts for one post, so the UI can show the
  /// tap immediately (server count + these) instead of waiting on the 30-minute
  /// flush. Each (post, kind) is 0 or 1 within a window.
  Future<({int views, int sent, int shares})> pendingCounts(String postId) async {
    final db = await _open();
    final rows = await db.query(
      'interaction_pending',
      where: 'post_id = ?',
      whereArgs: [postId],
    );
    var views = 0, sent = 0, shares = 0;
    for (final row in rows) {
      switch (row['kind']) {
        case 'view':
          views++;
        case 'sent':
          sent++;
        case 'share':
          shares++;
      }
    }
    return (views: views, sent: sent, shares: shares);
  }

  /// Sends every buffered tap as one batched increment per post, then — only on
  /// success — deletes exactly the rows it sent (rows recorded during the
  /// network round-trip survive for the next flush). A failed send keeps
  /// everything for the next attempt, so no count is ever dropped or the window
  /// reset without the server having received it.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final db = await _open();
      final rows = await db.query('interaction_pending');
      if (rows.isEmpty) return;

      // Aggregate to one item per post: {postId, views, sent, shares}.
      final perPost = <String, Map<String, int>>{};
      for (final row in rows) {
        final postId = row['post_id'] as String;
        final kind = row['kind'] as String;
        final item = perPost.putIfAbsent(postId, () => {'views': 0, 'sent': 0, 'shares': 0});
        switch (InteractionKind.values.firstWhere((k) => k.name == kind)) {
          case InteractionKind.view:
            item['views'] = item['views']! + 1;
          case InteractionKind.sent:
            item['sent'] = item['sent']! + 1;
          case InteractionKind.share:
            item['shares'] = item['shares']! + 1;
        }
      }

      final items = perPost.entries
          .map((e) => {'postId': e.key, ...e.value})
          .toList();
      await _api.post('/posts/interactions', body: {'items': items});

      // Delete exactly the (post_id, kind) pairs we just flushed.
      final batch = db.batch();
      for (final row in rows) {
        batch.delete(
          'interaction_pending',
          where: 'post_id = ? AND kind = ?',
          whereArgs: [row['post_id'], row['kind']],
        );
      }
      await batch.commit(noResult: true);
      _bump();
    } catch (_) {
      // Offline / server error — keep the rows and retry on the next tick,
      // app-background, or restart. Never resets the re-count window on failure.
    } finally {
      _flushing = false;
    }
  }
}

/// Optimistic not-yet-flushed view/send/share counts for a post, re-queried on
/// every record/flush. Count displays add these to the server counters so a tap
/// shows immediately; when the batch flushes and the server count catches up
/// (post:{id} channel), these return to zero — no double-count on a live post.
final pendingInteractionsProvider =
    StreamProvider.family<({int views, int sent, int shares}), String>((
      ref,
      postId,
    ) async* {
      final buffer = ref.watch(interactionBufferProvider);
      yield await buffer.pendingCounts(postId);
      await for (final _ in buffer.changes) {
        yield await buffer.pendingCounts(postId);
      }
    }, isAutoDispose: true);

final interactionBufferProvider = Provider<InteractionBuffer>((ref) {
  final buffer = InteractionBuffer(ref.watch(apiClientProvider));
  ref.onDispose(buffer.dispose);
  return buffer;
});
