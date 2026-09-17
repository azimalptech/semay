// `_startFor` fires one POST /stories/:id/view per slide and throws the Future
// away. That POST throws offline, on a 5xx, on the global rate limiter, and on
// a story the owner deleted from another device — and with nothing listening,
// the rejection was reported to the enclosing Zone: one uncaught async error
// per slide, every time a story set was watched on a flaky link. Both of its
// neighbours in the same method (markStoreSeen, the image precache) were
// already guarded; this one was not. A view count is best-effort, so there is
// no message to show — it simply must not escape.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/feed/feed_providers.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/features/story_viewer/story_providers.dart';
import 'package:semay/features/story_viewer/story_viewer_screen.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';

final _store = <String, dynamic>{
  'id': _storeId,
  'name': 'Audit Store',
  'avatarUrl': '',
};

PostDoc _story({String mediaType = 'image'}) => PostDoc({
  'id': 's1',
  'storeId': _storeId,
  // Deliberately unreachable, like story_reply_test's: the precache fails in a
  // widget test, which the viewer swallows.
  'mediaUrl': 'http://127.0.0.1:1/media/stories/s1'
      '${mediaType == 'video' ? '.mp4' : '.jpg'}',
  'mediaType': mediaType,
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'expiresAt': DateTime.now()
      .add(const Duration(hours: 23))
      .toUtc()
      .toIso8601String(),
});

void main() {
  testWidgets('a POST /stories/:id/view that fails does not escape the viewer', (
    tester,
  ) async {
    final api = FakeApi()..onGet = (_) => const {};
    // Only the view call fails. story-seen still answers, so a green run
    // proves the guard on THIS call rather than a screen that never got here.
    api.onPost = (path, _) {
      if (path == '/stories/s1/view') {
        throw ApiException(null, 'REQUEST_FAILED');
      }
      return const {};
    };
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // No runZonedGuarded here on purpose: an async error nobody handles is
    // reported to the test's own zone, which `flutter_test` turns into a test
    // failure — so the plain shape below is what pins the guard. (A probe on
    // the unguarded code fails with "ApiException(null, REQUEST_FAILED)
    // thrown running a test".)
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          // storeIds is empty, so this viewer is NOT the owner's — which is
          // what makes _startFor record a view at all.
          sessionControllerProvider.overrideWith(() => FakeSession()),
          storeDocProvider(
            _storeId,
          ).overrideWith((ref) => Stream.value(_store)),
          storeStoriesProvider(
            _storeId,
          ).overrideWith((ref) async => [_story()]),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StoryViewerScreen(storeId: _storeId)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      api.calls,
      contains('POST /stories/s1/view'),
      reason: 'the view was actually recorded — the test drove the real path',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'the rejected view POST must not escape as an async error',
    );
  });

  testWidgets('a video slide whose file cannot be fetched does not escape '
      'either, and still gets a timer', (tester) async {
    // The rest of the audit of _startFor: the image branch was already
    // guarded, the video branch was not. `MediaCache.getSingleFile` rejects
    // whenever the file cannot be had — offline, a 404 after the media reaper
    // ran, a broken cache entry (and, here, no path_provider under `flutter
    // test`) — and nobody awaits it, so it escaped exactly like the view POST
    // above AND left the slide with no AnimationController, freezing the
    // viewer on it forever. The fallback puts it on the standard 5 s timer.
    //
    // path_provider has to be answered for real: without it the cache manager
    // leaks its OWN MissingPluginException from an internal future, which is a
    // test-harness artifact and would mask (or fake) the thing under test.
    // With a real cache directory the only failure left is the fetch itself —
    // the story URL points at a closed port — and that is the future
    // _startFor holds.
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final channels =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cacheRoot = Directory.systemTemp.createTempSync('semay_story_cache');
    channels.setMockMethodCallHandler(
      pathProvider,
      (call) async => cacheRoot.path,
    );
    addTearDown(() {
      channels.setMockMethodCallHandler(pathProvider, null);
      if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
    });

    final api = FakeApi()..onGet = (_) => const {};
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionControllerProvider.overrideWith(() => FakeSession()),
          storeDocProvider(
            _storeId,
          ).overrideWith((ref) => Stream.value(_store)),
          storeStoriesProvider(
            _storeId,
          ).overrideWith((ref) async => [_story(mediaType: 'video')]),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StoryViewerScreen(storeId: _storeId)),
        ),
      ),
    );
    // runAsync, not a fake-async pump: getSingleFile is real I/O (and, under
    // `flutter test`, a missing path_provider) — it only rejects if actual
    // time is allowed to pass.
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the failed video fetch must not escape as an async error',
    );
  });
}
