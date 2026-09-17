// Chat attachments upload in the BACKGROUND, inside the outbox's drain — no
// screen is awaiting them, so their percentage has to be published rather
// than returned. These pin that channel and, just as importantly, that adding
// it did not touch the outbox's idempotency: the upload URL is still written
// back onto the queued row the moment it exists, so a retry re-POSTs but never
// re-uploads the bytes.

import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/outbox.dart';

import '../support/fake_outbox_db.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  Object? failWith;
  final posts = <String>[];

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    posts.add(path);
    if (failWith != null) throw failWith!;
    return const {'message': <String, dynamic>{'id': '1'}};
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeOutboxDb db;
  late _FakeApi api;
  late File media;
  late List<Map<String, double>> published;
  var n = 0;

  setUp(() {
    db = FakeOutboxDb();
    api = _FakeApi();
    media = File('${Directory.systemTemp.path}/semay_outbox_media_${n++}.jpg')
      ..writeAsBytesSync(List<int>.filled(4096, 7));
    published = [];
  });
  tearDown(() {
    try {
      if (media.existsSync()) media.deleteSync();
    } catch (_) {}
  });

  /// An outbox whose uploader reports [fractions] and then either returns a
  /// URL or throws.
  OutboxService makeOutbox({
    List<double> fractions = const [0.25, 0.5, 1.0],
    Object? uploadFails,
  }) {
    final service = OutboxService(
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
          }) async {
            for (final f in fractions) {
              onProgress?.call((bytes.length * f).round(), bytes.length);
            }
            if (uploadFails != null) throw uploadFails;
            return 'http://media.invalid/$folder/file.$fileExt';
          },
    );
    addTearDown(service.dispose);
    return service;
  }

  Future<void> queueAttachment(OutboxService outbox) => outbox.enqueue(
    OutboxKind.message,
    {
      'chatId': 'c1',
      'text': '',
      'senderRole': 'admin',
      'mediaType': 'image',
      'localMediaPath': media.path,
    },
    id: 'key-1',
  );

  Map<String, dynamic> payload() =>
      jsonDecode(db.rows.single['payload']! as String) as Map<String, dynamic>;

  test('the percentage is published per queued item, then cleared', () async {
    final outbox = makeOutbox();
    final sub = outbox.uploadProgress.listen(published.add);
    addTearDown(sub.cancel);

    await queueAttachment(outbox);
    await _settle();

    // Every fraction the uploader reported reached the stream under this
    // item's clientKey — that is what the bubble's ring reads.
    expect(
      published.map((e) => e['key-1']).toList(),
      containsAllInOrder(<double?>[0.0, 0.25, 0.5, 1.0]),
    );
    // …and the last word is "nothing is on the wire": the message was
    // accepted, the row is gone, so no ring is left hanging at a number.
    expect(published.last, isEmpty);
    expect(outbox.uploadProgressSnapshot, isEmpty);
    expect(api.posts, ['/chats/c1/messages']);
    expect(db.rows, isEmpty, reason: 'sent and removed');
  });

  test('a send that fails AFTER the upload keeps the URL — a retry never re-uploads', () async {
    api.failWith = ApiException(500, 'SERVER_ERROR');
    final outbox = makeOutbox();
    final sub = outbox.uploadProgress.listen(published.add);
    addTearDown(sub.cancel);

    await queueAttachment(outbox);
    await _settle();

    expect(db.rows, hasLength(1), reason: 'retryable: still queued');
    expect(
      payload()['mediaUrl'],
      'http://media.invalid/chats/file.jpg',
      reason: 'the bytes are up; the retry must only re-POST',
    );
    // The bar is not left frozen at 100 % on a message that has not been
    // sent.
    expect(published.last, isEmpty);
    expect(outbox.uploadProgressSnapshot, isEmpty);
  });

  test('an upload that fails leaves no URL and no stale percentage', () async {
    final outbox = makeOutbox(
      fractions: const [0.25],
      uploadFails: ApiException(null, 'REQUEST_FAILED'),
    );
    final sub = outbox.uploadProgress.listen(published.add);
    addTearDown(sub.cancel);

    await queueAttachment(outbox);
    await _settle();

    expect(db.rows, hasLength(1));
    expect(payload()['mediaUrl'], isNull, reason: 'nothing was uploaded');
    expect(published.map((e) => e['key-1']), contains(0.25));
    expect(published.last, isEmpty, reason: 'the ring stops claiming progress');
    // Still retryable, with the local file intact for the next attempt.
    expect(File(payload()['localMediaPath'] as String).existsSync(), isTrue);
  });

  test('logout clears queued uploads and their percentages', () async {
    final outbox = makeOutbox(uploadFails: ApiException(null, 'REQUEST_FAILED'));
    final sub = outbox.uploadProgress.listen(published.add);
    addTearDown(sub.cancel);

    await queueAttachment(outbox);
    await _settle();
    await outbox.clear();

    expect(db.rows, isEmpty);
    expect(outbox.uploadProgressSnapshot, isEmpty);
    expect(published.last, isEmpty);
  });
}
