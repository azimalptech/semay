// PostsService.uploadMedia's progress, driven through the REAL Dio (only the
// socket is stubbed).
//
// This is the test that would have caught the original defect: Dio fires
// onSendProgress once per chunk of the stream it is handed, so
// `Stream.fromIterable([bytes])` — the whole file as ONE chunk — can only
// ever report 100 %, once, after the bytes are already gone. A callback that
// fires exactly once at the end is indistinguishable from "no progress at
// all" on screen, which is what every surface showed.

import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/services/posts_service.dart';

import '../support/fakes.dart';

/// Stands in for the socket: drains the request stream (which is what makes
/// Dio's progress transformer run) and records what it received.
class _StubAdapter implements HttpClientAdapter {
  final chunkSizes = <int>[];
  RequestOptions? seen;
  Object? failWith;
  /// Fail partway through the body, as a dropped connection does.
  int? failAfterChunks;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen = options;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        chunkSizes.add(chunk.length);
        final stopAt = failAfterChunks;
        if (stopAt != null && chunkSizes.length >= stopAt) break;
      }
    }
    final failure = failWith;
    if (failure != null) throw failure;
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

PostsService _service(FakeApi api, Dio uploadDio) => PostsService(
  api,
  OutboxService(
    api,
    Connectivity(),
    hasSession: () => false,
    uploader:
        ({
          required folder,
          required bytes,
          required fileExt,
          required contentType,
          onProgress,
        }) async => '',
  ),
  InteractionBuffer(api),
  uploadClient: uploadDio,
);

void main() {
  late FakeApi api;
  late _StubAdapter adapter;
  late Dio dio;

  setUp(() {
    api = FakeApi()
      ..onPost = (path, body) => {
        'uploadUrl': 'http://upload.invalid/put',
        'publicUrl': 'http://media.invalid/file.jpg',
      };
    adapter = _StubAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });

  test('a multi-chunk PUT reports progress as it streams, ending at 1.0', () async {
    // 5 chunks and a bit: enough that a single 100 % callback is obviously
    // wrong.
    final bytes = Uint8List(PostsService.uploadChunkBytes * 5 + 123);
    final reports = <List<int>>[];

    final url = await _service(api, dio).uploadMedia(
      folder: 'posts',
      bytes: bytes,
      fileExt: 'jpg',
      contentType: 'image/jpeg',
      onProgress: (sent, total) => reports.add([sent, total]),
    );

    expect(url, 'http://media.invalid/file.jpg');
    expect(api.calls, contains('POST /media/upload-url'));

    // The bytes really were sliced — six chunks, the last one short.
    expect(adapter.chunkSizes.length, 6);
    expect(adapter.chunkSizes.last, 123);
    expect(
      adapter.chunkSizes.fold<int>(0, (a, b) => a + b),
      bytes.length,
      reason: 'every byte is sent exactly once',
    );

    // …and the callback tracked them, rather than firing once at the end.
    expect(reports.length, greaterThanOrEqualTo(6));
    final sent = [for (final r in reports) r.first];
    expect(sent.first, lessThan(bytes.length), reason: 'progress before the end');
    expect(sent, orderedEquals(List.of(sent)..sort()), reason: 'monotonic');
    expect(sent.last, bytes.length);
    expect(reports.every((r) => r[1] == bytes.length), isTrue);
    expect(reports.map((r) => r.first / r[1]).last, 1.0);
  });

  test('the content-length header still matches the file exactly', () async {
    final bytes = Uint8List(PostsService.uploadChunkBytes + 7);
    await _service(api, dio).uploadMedia(
      folder: 'stores',
      bytes: bytes,
      fileExt: 'jpg',
      contentType: 'image/jpeg',
    );
    // The signed PUT needs the length up front; progress needs the stream.
    // Both, or the upload 400s / the bar never moves.
    expect(
      adapter.seen!.headers[Headers.contentLengthHeader],
      bytes.length,
    );
    expect(adapter.seen!.headers[Headers.contentTypeHeader], 'image/jpeg');
  });

  test('a PUT with no progress callback still uploads (callers may omit it)', () async {
    final bytes = Uint8List(1024);
    final url = await _service(api, dio).uploadMedia(
      folder: 'chats',
      bytes: bytes,
      fileExt: 'jpg',
      contentType: 'image/jpeg',
    );
    expect(url, 'http://media.invalid/file.jpg');
    expect(adapter.chunkSizes, [1024]);
  });

  test('a failed PUT throws — the caller reports it, nothing is swallowed', () async {
    adapter.failAfterChunks = 1;
    adapter.failWith = DioException(
      requestOptions: RequestOptions(path: '/put'),
      type: DioExceptionType.connectionError,
    );
    final progress = <double>[];
    await expectLater(
      _service(api, dio).uploadMedia(
        folder: 'posts',
        bytes: Uint8List(PostsService.uploadChunkBytes * 4),
        fileExt: 'jpg',
        contentType: 'image/jpeg',
        onProgress: (sent, total) => progress.add(sent / total),
      ),
      throwsA(isA<DioException>()),
    );
    // Whatever the bar had reached, it never reached 1.0 — the surface shows
    // the failure, not a finished upload.
    expect(progress.last, lessThan(1.0));
  });
}
