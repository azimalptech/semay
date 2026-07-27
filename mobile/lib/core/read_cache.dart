import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Read-side local cache (Phase 9b) — persists the first page of list fetches
/// (feed, store posts/reels) so a fresh launch paints instantly from the last
/// seen data instead of a blank spinner, then supersedes it with the network
/// result. Replaces Firestore's automatic `Source.cache` instant-paint. Small
/// and best-effort: a cache miss or read error just falls through to network.
class ReadCacheService {
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'semay_read_cache.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE read_cache(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      '''),
    );
    return _db!;
  }

  /// Returns the cached JSON list for [key], or null on miss/error.
  Future<List<Map<String, dynamic>>?> readList(String key) async {
    try {
      final db = await _open();
      final rows = await db.query('read_cache', where: 'key = ?', whereArgs: [key], limit: 1);
      if (rows.isEmpty) return null;
      final decoded = jsonDecode(rows.first['value'] as String) as List<dynamic>;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeList(String key, List<Map<String, dynamic>> value) async {
    try {
      final db = await _open();
      await db.insert('read_cache', {
        'key': key,
        'value': jsonEncode(value),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {
      // Best-effort — never fail a fetch over a cache write.
    }
  }
}

final readCacheProvider = Provider<ReadCacheService>((ref) => ReadCacheService());
