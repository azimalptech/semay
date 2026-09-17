// What the store admin sees while a post uploads, and what they are told when
// it lands or fails. Drives the REAL PostComposerScreen with a scripted
// PostsService: one that emits 25 % / 50 % / 100 % and finishes, and one that
// throws.
//
// Before this pass the screen showed a bare spinner for however long a reel
// took, popped in silence on success, and printed the raw exception
// ("Ýüklenmedi: ApiException(400, INVALID_INPUT)") on failure.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/core/upload_progress.dart';
import 'package:semay/features/post_composer/post_composer_screen.dart';
import 'package:semay/services/posts_service.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';
const _s = S(false);

/// One SnackBar widget is built per Scaffold registered with the messenger
/// (the parent screen's and the composer's, while both are mounted), so these
/// assert "shown", not "shown once".
Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Finder get _publish => find.widgetWithText(FilledButton, _s.publish);

/// A createPost whose progress and outcome the test drives by hand.
class _ScriptedPosts extends PostsService {
  _ScriptedPosts(FakeApi api, {this.failWith})
    : super(
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
      );

  final Object? failWith;
  final done = Completer<void>();
  UploadProgressCallback? report;

  @override
  Future<void> createPost({
    required String storeId,
    required String type,
    required List<XFile> files,
    required String caption,
    num? price,
    UploadProgressCallback? onProgress,
  }) {
    report = onProgress;
    final failure = failWith;
    if (failure != null) return Future<void>.error(failure);
    return done.future;
  }
}

double? _barValue(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
    .value;

bool _publishEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed !=
    null;

void main() {
  late File file;
  var n = 0;

  setUp(() {
    file = File('${Directory.systemTemp.path}/semay_composer_${n++}.jpg')
      ..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
  });
  tearDown(() {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  });

  Future<_ScriptedPosts> pump(WidgetTester tester, {Object? failWith}) async {
    final api = FakeApi();
    final posts = _ScriptedPosts(api, failWith: failWith);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          l10nProvider.overrideWithValue(_s),
          postsServiceProvider.overrideWithValue(posts),
        ],
        // Pushed over a parent Scaffold so the confirmation has somewhere to
        // land after the composer pops.
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PostComposerScreen(
                      storeId: _storeId,
                      type: 'carousel',
                      files: [XFile(file.path), XFile(file.path)],
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PostComposerScreen), findsOneWidget);
    // A price, so the "no price?" confirm dialog stays out of the way.
    await tester.enterText(find.byType(TextField).at(1), '10');
    await tester.pump();
    return posts;
  }

  testWidgets('one percentage for the whole carousel, and Publish stays dead', (
    tester,
  ) async {
    final posts = await pump(tester);

    await tester.tap(_publish);
    await tester.pump();

    // Disabled from the first frame, and saying so — not a bare spinner.
    expect(_publishEnabled(tester), isFalse);
    expect(find.text(_s.uploadingMedia), findsOneWidget);
    expect(_barValue(tester), isNull, reason: 'indeterminate until byte one');

    for (final fraction in [0.25, 0.5, 1.0]) {
      posts.report!(
        UploadProgress(sentBytes: (fraction * 400).round(), totalBytes: 400),
      );
      await tester.pump();
      expect(
        find.text(_s.uploadingPercent((fraction * 100).round())),
        findsOneWidget,
      );
      expect(_barValue(tester), fraction);
      expect(_publishEnabled(tester), isFalse);
    }

    // The POST after the last byte: still disabled, still 100 %.
    expect(find.byType(PostComposerScreen), findsOneWidget);

    posts.done.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the pop transition

    expect(tester.takeException(), isNull);
    expect(find.byType(PostComposerScreen), findsNothing, reason: 'popped');
    expect(_snack(_s.postPublished), findsWidgets);
  });

  testWidgets('a failed publish names the reason and hands the button back', (
    tester,
  ) async {
    await pump(
      tester,
      failWith: ApiException(400, 'INVALID_INPUT', body: {'error': 'INVALID_INPUT'}),
    );

    await tester.tap(_publish);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(_snack(_s.uploadFailed(_s.invalidInput)), findsWidgets);
    expect(find.textContaining('ApiException'), findsNothing);
    // The picked files are untouched and Publish is live again: retry is a
    // second tap, not a re-pick.
    expect(find.byType(PostComposerScreen), findsOneWidget);
    expect(_publishEnabled(tester), isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a video over the cap is refused in the user\'s language', (
    tester,
  ) async {
    await pump(tester, failWith: const MediaTooLargeException(100 * 1024 * 1024));

    await tester.tap(_publish);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_snack(_s.uploadFailed(_s.videoTooLarge(100))), findsWidgets);
    expect(
      find.textContaining('Video must be under'),
      findsNothing,
      reason: 'the English exception text must never reach the screen',
    );
  });

  testWidgets('backing out mid-upload: the late callbacks kill nothing', (
    tester,
  ) async {
    final posts = await pump(tester);

    await tester.tap(_publish);
    await tester.pump();
    posts.report!(const UploadProgress(sentBytes: 100, totalBytes: 400));
    await tester.pump();
    expect(find.text(_s.uploadingPercent(25)), findsOneWidget);

    // Back out while the bytes are still moving — the upload is not
    // cancellable, so its callbacks keep arriving at a dead State.
    Navigator.of(tester.element(find.byType(PostComposerScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the pop transition
    expect(find.byType(PostComposerScreen), findsNothing);

    posts.report!(const UploadProgress(sentBytes: 300, totalBytes: 400));
    posts.report!(const UploadProgress(sentBytes: 400, totalBytes: 400));
    posts.done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull, reason: 'no setState after dispose');
    // The post still went up, so it is still confirmed — on the screen the
    // composer returned to.
    expect(_snack(_s.postPublished), findsWidgets);
  });
}
