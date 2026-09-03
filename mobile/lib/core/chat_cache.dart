import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'session.dart';

/// Newest messages kept per thread. Older history is paged from the server
/// on demand (ChatMessagesNotifier.loadOlder) and not retained here.
const chatCacheMessagesPerChat = 500;

/// Local copy of the chat list and the recent window of every thread the user
/// has opened — what makes a thread open instantly (and read offline) the way
/// Instagram's does, instead of showing a spinner until the server answers.
///
/// Write-through, not a source of truth: the providers in chat_providers.dart
/// paint from here first, then let the REST seed and the socket snapshot
/// supersede it row by row, persisting every change back. Everything is
/// best-effort — a read error is a cache miss, a write error is ignored — so
/// the cache can never make chat worse than having no cache.
///
/// Belongs to exactly one account: the owner uid is recorded in `meta`, and
/// opening it under a different uid (or a logout) wipes it, so nothing from
/// one session can ever be painted for the next.
class ChatCache {
  ChatCache({required String? Function() ownerUid}) : _ownerUid = ownerUid;

  final String? Function() _ownerUid;
  Database? _db;
  String? _checkedOwner;

  Future<Database?> _open() async {
    final uid = _ownerUid();
    if (uid == null) return null; // nobody signed in — nothing to cache for
    _db ??= await openDatabase(
      p.join(await getDatabasesPath(), 'semay_chat_cache.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await db.execute('''
          CREATE TABLE chats(
            id TEXT PRIMARY KEY,
            store_id TEXT NOT NULL,
            json TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE messages(
            chat_id TEXT NOT NULL,
            id INTEGER NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (chat_id, id)
          )
        ''');
      },
    );
    final db = _db!;
    if (_checkedOwner != uid) {
      final rows = await db.query('meta', where: 'key = ?', whereArgs: ['owner']);
      final owner = rows.isEmpty ? null : rows.first['value'] as String;
      if (owner != uid) {
        await _wipe(db);
        await db.insert('meta', {'key': 'owner', 'value': uid}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      _checkedOwner = uid;
    }
    return db;
  }

  Future<void> _wipe(Database db) async {
    await db.delete('chats');
    await db.delete('messages');
    await db.delete('meta');
  }

  // ── chat list ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> chats() async {
    try {
      final db = await _open();
      if (db == null) return const [];
      final rows = await db.query('chats');
      return rows.map((r) => jsonDecode(r['json'] as String) as Map<String, dynamic>).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>?> chat(String id) async {
    try {
      final db = await _open();
      if (db == null) return null;
      final rows = await db.query('chats', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return null;
      return jsonDecode(rows.first['json'] as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// A list snapshot is the whole visible list for its scope — all of the
  /// user's chats, or one store's for an admin — so rows that fell out of it
  /// (hidden, deleted) are removed, not just the incoming ones written.
  Future<void> replaceChats(Iterable<Map<String, dynamic>> rows, {String? storeId}) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.transaction((tx) async {
        if (storeId == null) {
          await tx.delete('chats');
        } else {
          await tx.delete('chats', where: 'store_id = ?', whereArgs: [storeId]);
        }
        final batch = tx.batch();
        for (final chat in rows) {
          batch.insert('chats', _chatRow(chat), conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> upsertChat(Map<String, dynamic> chat) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.insert('chats', _chatRow(chat), conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> removeChat(String id) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.delete('chats', where: 'id = ?', whereArgs: [id]);
    } catch (_) {
      /* best-effort */
    }
  }

  Map<String, Object?> _chatRow(Map<String, dynamic> chat) => {
    'id': chat['id'] as String,
    'store_id': chat['storeId'] as String? ?? '',
    'json': jsonEncode(chat),
  };

  // ── messages ───────────────────────────────────────────────────────────

  /// The newest [chatCacheMessagesPerChat] messages of a thread, oldest first.
  Future<List<Map<String, dynamic>>> messages(String chatId) async {
    try {
      final db = await _open();
      if (db == null) return const [];
      final rows = await db.query(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [chatId],
        orderBy: 'id DESC',
        limit: chatCacheMessagesPerChat,
      );
      return rows.reversed
          .map((r) => jsonDecode(r['json'] as String) as Map<String, dynamic>)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> upsertMessages(String chatId, Iterable<Map<String, dynamic>> rows) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.transaction((tx) async {
        final batch = tx.batch();
        for (final m in rows) {
          final id = int.tryParse('${m['id']}');
          if (id == null) continue; // optimistic "pending-…" rows never land here
          batch.insert(
            'messages',
            {'chat_id': chatId, 'id': id, 'json': jsonEncode(m)},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        // Keep the window bounded: drop whatever is older than the newest N.
        await tx.rawDelete(
          'DELETE FROM messages WHERE chat_id = ? AND id NOT IN '
          '(SELECT id FROM messages WHERE chat_id = ? ORDER BY id DESC LIMIT ?)',
          [chatId, chatId, chatCacheMessagesPerChat],
        );
      });
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> removeMessage(String chatId, String id) async {
    try {
      final db = await _open();
      if (db == null) return;
      final parsed = int.tryParse(id);
      if (parsed == null) return;
      await db.delete('messages', where: 'chat_id = ? AND id = ?', whereArgs: [chatId, parsed]);
    } catch (_) {
      /* best-effort */
    }
  }

  /// Logout. The owner check would wipe on the next login anyway; this just
  /// does it now so nothing of the old session sits on disk in between.
  Future<void> clear() async {
    try {
      final db = _db;
      if (db == null) return;
      await _wipe(db);
      _checkedOwner = null;
    } catch (_) {
      /* best-effort */
    }
  }

  void dispose() {
    _db?.close();
    _db = null;
  }
}

final chatCacheProvider = Provider<ChatCache>((ref) {
  final cache = ChatCache(ownerUid: () => ref.read(sessionControllerProvider).value?.uid);
  ref.listen(sessionControllerProvider, (previous, next) {
    if (previous?.value != null && next.value == null) unawaited(cache.clear());
  });
  ref.onDispose(cache.dispose);
  return cache;
});
