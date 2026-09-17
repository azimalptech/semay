// The story composer is the other half of the story-ring feature: the new
// store-profile ring routes an own store with no stories straight into
// showAddStorySheet, and its "+" badge does the same. Two defects were fixed
// 40 lines from an identical one that WAS fixed (edit_store_screen's avatar
// picker), and neither was covered:
//
//   * a denied camera/photo permission escaped the sheet's onTap as an
//     unhandled zone error — the sheet just sat there and said nothing;
//   * publishing rendered the RAW exception ("Ýüklenmedi: ApiException(400,
//     INVALID_INPUT)"), and backing out mid-upload skipped the two
//     invalidates that are the only liveness path a publish has (there is no
//     realtime event for stories), so a published story stayed invisible on
//     both rings until a pull-to-refresh.
//
// These drive the REAL sheet and the REAL StoryPreviewScreen.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/shared/story_bar_provider.dart';
import 'package:semay/features/story_composer/add_story_flow.dart';
import 'package:semay/features/story_viewer/story_providers.dart';
import 'package:semay/services/posts_service.dart';
import 'package:semay/services/stories_service.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';
const _s = S(false);

Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

/// A StoriesService whose createStory is scripted per test.
class _FakeStories extends StoriesService {
  _FakeStories(FakeApi api, this._create)
    : super(
        api,
        PostsService(
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
                }) async => '',
          ),
          InteractionBuffer(api),
        ),
      );

  final Future<void> Function() _create;

  @override
  Future<void> createStory({
    required String storeId,
    required XFile mediaFile,
    required String mediaType,
  }) => _create();
}

FakeApi _api() => FakeApi()
  ..onGet = (path) {
    if (path == '/stories/rings') return {'rings': <dynamic>[]};
    if (path == '/stores/$_storeId/stories') return {'stories': <dynamic>[]};
    return const {};
  };

Future<Object?> _guarded(Future<void> Function() body) async {
  Object? escaped;
  final done = Completer<void>();
  runZonedGuarded(() async {
    await body();
    if (!done.isCompleted) done.complete();
  }, (e, _) {
    escaped ??= e;
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  return escaped;
}

void main() {
  testWidgets('a refused camera is reported on the sheet, and nothing escapes', (
    tester,
  ) async {
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      picker,
      (call) async => throw PlatformException(code: 'photo_access_denied'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(picker, null));

    final api = _api();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionControllerProvider.overrideWith(
            () => FakeSession(role: 'admin', storeIds: const [_storeId]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    showAddStorySheet(context, ref, storeId: _storeId),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(_s.newStory), findsOneWidget);

    final escaped = await _guarded(() async {
      await tester.tap(find.text(_s.takePhoto));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });

    expect(escaped, isNull, reason: 'the picker failure must not escape');
    expect(tester.takeException(), isNull);
    expect(_snack(_s.mediaPickFailed), findsOneWidget);
  });

  group('StoryPreviewScreen', () {
    late File file;
    var n = 0;

    setUp(() {
      file = File('${Directory.systemTemp.path}/semay_story_preview_${n++}.jpg')
        ..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
    });
    tearDown(() {
      // Best-effort: the preview's FutureBuilder may still hold a handle.
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    });

    Future<FakeApi> pump(
      WidgetTester tester,
      Future<void> Function() createStory,
    ) async {
      final api = _api();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sessionControllerProvider.overrideWith(
              () => FakeSession(role: 'admin', storeIds: const [_storeId]),
            ),
            storiesServiceProvider.overrideWith(
              (ref) => _FakeStories(api, createStory),
            ),
          ],
          child: MaterialApp(
            // The home ring bar and the store's story list are watched here,
            // exactly as they are by the screens underneath the composer —
            // that is what makes the publish invalidates observable (an
            // unwatched provider would simply be disposed).
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(storyBarProvider);
                ref.watch(storeStoriesProvider(_storeId));
                return Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () =>
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => StoryPreviewScreen(
                                storeId: _storeId,
                                files: [XFile(file.path)],
                                mediaTypes: const ['image'],
                              ),
                            ),
                          ),
                      child: const Text('open'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      // No pumpAndSettle anywhere in this group: the preview shows a
      // CircularProgressIndicator while the picked file is read (real I/O
      // that does not progress under the fake clock), and another inside the
      // Publish button while it uploads — both animate forever, so
      // pumpAndSettle would simply time out.
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(StoryPreviewScreen), findsOneWidget);
      return api;
    }

    testWidgets('a failed publish names the reason, never the raw exception', (
      tester,
    ) async {
      await pump(
        tester,
        () async => throw ApiException(
          400,
          'INVALID_INPUT',
          body: {'error': 'INVALID_INPUT'},
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, _s.publish));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(_snack(_s.invalidInput), findsOneWidget);
      expect(find.textContaining('ApiException'), findsNothing);
      expect(
        find.byType(StoryPreviewScreen),
        findsOneWidget,
        reason: 'stays, so the publish can be retried',
      );
    });

    testWidgets('a dead network reads as noConnection', (tester) async {
      await pump(tester, () async => throw ApiException(null, 'REQUEST_FAILED'));

      await tester.tap(find.widgetWithText(FilledButton, _s.publish));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(_snack(_s.noConnection), findsOneWidget);
    });

    testWidgets(
      'backing out mid-publish still refreshes both rings',
      (tester) async {
        final upload = Completer<void>();
        final api = await pump(tester, () => upload.future);
        final ringsBefore = api.count('GET /stories/rings');
        final listBefore = api.count('GET /stores/$_storeId/stories');

        await tester.tap(find.widgetWithText(FilledButton, _s.publish));
        await tester.pump();

        // Close the preview while the upload is still in flight.
        await tester.tap(find.byType(IconButton));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(StoryPreviewScreen), findsNothing);

        upload.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(tester.takeException(), isNull);
        expect(
          api.count('GET /stories/rings'),
          greaterThan(ringsBefore),
          reason: 'the home story bar must show the story that WAS published',
        );
        expect(
          api.count('GET /stores/$_storeId/stories'),
          greaterThan(listBefore),
          reason: 'and so must the store-profile ring',
        );
      },
    );
  });
}
