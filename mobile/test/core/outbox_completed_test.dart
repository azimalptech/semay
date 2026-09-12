// The one production line the Liked/Saved fix stands on:
//
//   drain() -> await _send(item) -> await _remove(...) -> _completed.add(kind)
//
// Its PLACEMENT is the whole design argument — after the send returned (a
// refetch any earlier re-caches the pre-toggle list, because
// PostsService.toggleLike returns at enqueue time) and not on the drop paths
// (an item the server rejected never became server state). Nothing else in the
// suite touches drain(), so without this the emission could be deleted, moved
// before the send, or moved into the error branch with every test still green
// and the owner's bug back.
//
// sqflite is faked rather than run (the service takes an `openDb` seam for
// exactly this; its own factory refuses a stand-in): the point here is the
// ordering of the emission, not SQL.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/outbox.dart';

/// Just enough of sqflite to hold outbox rows in a list.
class _FakeDb implements Database {
  final rows = <Map<String, Object?>>[];
  var _seq = 0;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    rows.removeWhere((r) => r['id'] == values['id']);
    // `_seq` breaks the tie between rows enqueued inside the same
    // millisecond, which real SQLite's rowid order would do.
    rows.add(Map<String, Object?>.of(values)..['_seq'] = _seq++);
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    var out = where == null
        ? [...rows]
        : rows.where((r) => r['id'] == whereArgs!.first).toList();
    out.sort((a, b) {
      final byTime = (a['created_at']! as int).compareTo(
        b['created_at']! as int,
      );
      return byTime != 0
          ? byTime
          : (a['_seq']! as int).compareTo(b['_seq']! as int);
    });
    if (limit != null) out = out.take(limit).toList();
    return out.map(Map<String, Object?>.of).toList();
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final before = rows.length;
    rows.removeWhere((r) => r['id'] == whereArgs!.first);
    return before - rows.length;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    // The only raw update in the service is `attempts = attempts + 1`.
    for (final r in rows) {
      if (r['id'] == arguments!.first) {
        r['attempts'] = (r['attempts']! as int) + 1;
      }
    }
    return 1;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    for (final r in rows) {
      if (r['id'] == whereArgs!.first) r.addAll(values);
    }
    return 1;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  /// Held open so a test can assert what has and has not been emitted while
  /// the request is still in flight.
  Completer<void>? gate;
  Object? failWith;
  final posts = <String>[];
  final deletes = <String>[];

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    posts.add(path);
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> delete(String path, {Object? body}) async {
    deletes.add(path);
    if (gate != null) await gate!.future;
    if (failWith != null) throw failWith!;
    return const {};
  }
}

/// enqueue() starts a drain of its own, so a later `await drain()` returns
/// immediately (the running one just records that another pass is wanted).
/// Waiting for the queue to go quiet is what "the send finished" means here.
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeDb db;
  late _FakeApi api;
  late OutboxService outbox;
  late List<OutboxKind> emitted;
  late StreamSubscription<OutboxKind> sub;

  setUp(() {
    db = _FakeDb();
    api = _FakeApi();
    outbox = OutboxService(
      api,
      Connectivity(),
      hasSession: () => true,
      openDb: () async => db,
      uploader:
          ({
            required folder,
            required bytes,
            required fileExt,
            required contentType,
          }) async => throw UnimplementedError(),
    );
    emitted = [];
    sub = outbox.completed.listen(emitted.add);
  });

  tearDown(() async {
    await sub.cancel();
    outbox.dispose();
  });

  test('a like emits completed once, and only after the POST returns', () async {
    final gate = api.gate = Completer<void>();
    await outbox.enqueue(OutboxKind.like, {'postId': 'p1'});
    await _settle();

    expect(api.posts, ['/posts/p1/like']);
    expect(
      emitted,
      isEmpty,
      reason:
          'emitting while the write is still in flight would refetch the '
          'pre-toggle list and cache it',
    );

    gate.complete();
    await _settle();

    expect(emitted, [OutboxKind.like]);
    expect(db.rows, isEmpty, reason: 'the row is gone before the signal');
  });

  test('unlike/save/unsave each emit their own kind', () async {
    await outbox.enqueue(OutboxKind.unlike, {'postId': 'p1'});
    await outbox.enqueue(OutboxKind.save, {'postId': 'p2'});
    await outbox.enqueue(OutboxKind.unsave, {'postId': 'p3'});
    await _settle();

    expect(emitted, [OutboxKind.unlike, OutboxKind.save, OutboxKind.unsave]);
  });

  test('a permanent 4xx drops the item and emits nothing', () async {
    api.failWith = ApiException(400, 'BAD_REQUEST');
    await outbox.enqueue(OutboxKind.like, {'postId': 'p1'});
    await _settle();

    expect(db.rows, isEmpty, reason: 'a poison item must not wedge the queue');
    expect(
      emitted,
      isEmpty,
      reason: 'the server rejected it, so there is nothing new to re-read',
    );
  });

  test('a retryable failure emits nothing and keeps the item queued', () async {
    api.failWith = ApiException(500, 'SERVER_ERROR');
    await outbox.enqueue(OutboxKind.like, {'postId': 'p1'});
    await _settle();

    expect(emitted, isEmpty);
    expect(db.rows, hasLength(1));
    expect(db.rows.single['attempts'], 1);

    // Signal comes back minutes later: the replay is what refreshes the grid.
    api.failWith = null;
    await outbox.drain();
    await _settle();
    expect(emitted, [OutboxKind.like]);
  });
}
