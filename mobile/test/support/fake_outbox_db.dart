// An in-memory stand-in for the outbox's SQLite file, shared by the outbox
// tests. The service takes an `openDb` seam for exactly this (its own factory
// refuses a stand-in): what those tests are about is drain()'s ordering and
// what it publishes, not SQL.

import 'package:sqflite/sqflite.dart';

/// Just enough of sqflite to hold outbox rows in a list.
class FakeOutboxDb implements Database {
  final rows = <Map<String, Object?>>[];
  var seq = 0;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    rows.removeWhere((r) => r['id'] == values['id']);
    // `seq` breaks the tie between rows enqueued inside the same
    // millisecond, which real SQLite's rowid order would do.
    rows.add(Map<String, Object?>.of(values)..['seq'] = seq++);
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
          : (a['seq']! as int).compareTo(b['seq']! as int);
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
    // No `where` is the service's logout wipe (`db.delete('outbox')`); with
    // one it is always `id = ?`.
    if (where == null) {
      rows.clear();
    } else {
      rows.removeWhere((r) => r['id'] == whereArgs!.first);
    }
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

