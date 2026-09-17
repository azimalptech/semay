// "Delete" on a failed message — the second half of the choice the owner
// asked for (Retry / Delete), and the half that had no implementation at all:
// until now a message the outbox had given up on could only be retried, so one
// that could never succeed stayed red in the thread for good.
//
// discard() has to take the row OUT of the queue (so the optimistic bubble
// stops being rendered and nothing is sent later when the connection returns)
// and tell the UI ([changes]) that it did. sqflite is faked through the
// service's own `openDb` seam, as in the other outbox tests.

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/outbox.dart';

import '../support/fake_outbox_db.dart';

const _chatId = 'u1_s1';

/// The ids still in the queue. Read off the fake table rather than through
/// pendingMessages(), whose `kind = ?` query the fake does not model (it only
/// understands `id = ?` — see fake_outbox_db.dart).
List<String> _queued(FakeOutboxDb db) =>
    db.rows.map((r) => r['id']! as String).toList();

class _DeadApi extends ApiClient {
  _DeadApi() : super(Dio());

  var posts = 0;

  /// Every send fails, which is how a message gets into the failed state in
  /// the first place.
  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    posts++;
    throw ApiException(null, 'REQUEST_FAILED');
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeOutboxDb db;
  late _DeadApi api;
  late OutboxService outbox;

  setUp(() {
    db = FakeOutboxDb();
    api = _DeadApi();
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
            onProgress,
          }) async => '',
    );
  });

  tearDown(() => outbox.dispose());

  test('discard removes the queued message and announces the change', () async {
    final changes = <void>[];
    final sub = outbox.changes.listen(changes.add);
    addTearDown(sub.cancel);

    await outbox.enqueue(OutboxKind.message, {
      'chatId': _chatId,
      'text': 'salam',
      'senderRole': 'user',
    }, id: 'key-1');
    await _settle();
    expect(_queued(db), ['key-1']);
    final sendsBefore = api.posts;

    await outbox.discard('key-1');
    await _settle();

    expect(
      _queued(db),
      isEmpty,
      reason: 'the optimistic bubble has nothing left to render',
    );
    expect(changes, isNotEmpty, reason: 'the thread has to hear about it');
    // And it is gone for good: a later drain (the automatic one on reconnect)
    // must not send what the user threw away.
    await outbox.drain();
    await _settle();
    expect(api.posts, sendsBefore);
  });

  test('discarding one message leaves the others queued', () async {
    await outbox.enqueue(OutboxKind.message, {
      'chatId': _chatId,
      'text': 'birinji',
      'senderRole': 'user',
    }, id: 'key-1');
    await outbox.enqueue(OutboxKind.message, {
      'chatId': _chatId,
      'text': 'ikinji',
      'senderRole': 'user',
    }, id: 'key-2');
    await _settle();

    await outbox.discard('key-1');
    await _settle();

    expect(_queued(db), ['key-2']);
  });

  test('discarding something already gone is harmless', () async {
    await outbox.discard('never-existed');
    await _settle();
    expect(_queued(db), isEmpty);
  });
}
