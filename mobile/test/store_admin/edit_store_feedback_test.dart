// EditStoreScreen (admin "Edit Profile": PATCH /stores/:id) used to be
// try/finally only — a 400 or a dead network escaped the button callback as
// an unhandled async error with nothing on screen, and a success popped
// without a word. These drive the REAL screen, pushed over a parent Scaffold
// so the post-pop confirmation has somewhere to land.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/store_admin/edit_store_screen.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/posts_service.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';
const _s = S(false);

final _store = <String, dynamic>{
  'id': _storeId,
  'name': 'Audit Store',
  'tagline': '',
  'address': '',
  'phone': '',
  'avatarUrl': '',
};

Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Finder get _save => find.widgetWithText(FilledButton, _s.save);

Finder get _nameField => find.byType(TextField).first;

/// An avatar upload that never returns — holds the screen in "uploading".
class _HangingUploads extends PostsService {
  _HangingUploads(FakeApi api)
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
              }) async => '',
        ),
        InteractionBuffer(api),
      );

  @override
  Future<String> uploadMedia({
    required String folder,
    required Uint8List bytes,
    required String fileExt,
    required String contentType,
  }) => Completer<String>().future;
}

/// An avatar upload that fails — the picker and cropper both succeeded.
class _FailingUploads extends _HangingUploads {
  _FailingUploads(super.api);

  @override
  Future<String> uploadMedia({
    required String folder,
    required Uint8List bytes,
    required String fileExt,
    required String contentType,
  }) async => throw ApiException(null, 'REQUEST_FAILED');
}

Future<FakeApi> _pump(
  WidgetTester tester, {
  PostsService Function(FakeApi api)? posts,
  // Fires once per storeDocProvider build — how the tests below observe the
  // invalidate that re-reads the store profile this screen returns to.
  void Function()? onStoreDocBuild,
}) async {
  final api = FakeApi();
  // A phone-shaped surface. The default 800x600 test view is SHORTER than
  // this form (avatar + four labelled fields ≈ 620 px), so Save fell past the
  // ListView's cache extent and was never built at all: every `_save` finder
  // matched nothing, which is what these tests were actually failing on.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionControllerProvider.overrideWith(
          () => FakeSession(role: 'admin', storeIds: const [_storeId]),
        ),
        storeDocProvider(_storeId).overrideWith((ref) {
          onStoreDocBuild?.call();
          return Stream.value(_store);
        }),
        if (posts != null) postsServiceProvider.overrideWithValue(posts(api)),
      ],
      child: MaterialApp(
        home: Scaffold(
          // The parent WATCHES storeDocProvider, exactly as the store profile
          // this screen is pushed from does — that listener is what makes the
          // post-save invalidate a real re-read (an unwatched autoDispose
          // family would just be disposed and nothing would be observable).
          body: Consumer(
            builder: (context, ref, _) {
              ref.watch(storeDocProvider(_storeId));
              return Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EditStoreScreen(storeId: _storeId),
                    ),
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(EditStoreScreen), findsOneWidget);
  return api;
}

/// Taps Save inside a guarded zone: the old try/finally let the failure out
/// of the button callback as an uncaught async error, which is exactly what
/// [escaped] would catch.
///
/// The completion is driven by an explicit [Completer] rather than by awaiting
/// what `runZonedGuarded` returns. In an error zone an uncaught async error is
/// handed to the handler and the body's Future is then NEVER completed — so
/// awaiting it means that the one outcome this helper exists to detect hangs
/// the test until the 10-minute timeout instead of reporting itself. Now an
/// escape completes the wait too, and the caller's `expect(..., isNull)` says
/// what escaped.
Future<Object?> _tapSaveGuarded(WidgetTester tester) async {
  Object? escaped;
  final done = Completer<void>();
  runZonedGuarded(() async {
    await tester.tap(_save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    if (!done.isCompleted) done.complete();
  }, (e, _) {
    escaped ??= e;
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  return escaped;
}

Finder get _avatarTap => find
    .ancestor(of: find.byType(CircleAvatar).first, matching: find.byType(GestureDetector))
    .first;

void main() {
  testWidgets('a refused photo library is reported, and nothing escapes', (
    tester,
  ) async {
    // The picker and the cropper — not the upload — are what actually fail on
    // a device: image_picker throws a PlatformException when the photo
    // permission is denied (iOS photo_access_denied, Android 13+
    // READ_MEDIA_IMAGES) or an activity result comes back broken. Those two
    // awaits sat OUTSIDE the try, so the throw left the tap handler as a zone
    // error: the sheet never opened and the admin was told nothing at all.
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      picker,
      (call) async => throw PlatformException(code: 'photo_access_denied'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(picker, null));

    await _pump(tester);

    Object? escaped;
    final done = Completer<void>();
    runZonedGuarded(() async {
      await tester.tap(_avatarTap);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      if (!done.isCompleted) done.complete();
    }, (e, _) {
      escaped ??= e;
      if (!done.isCompleted) done.complete();
    });
    await done.future;

    expect(escaped, isNull, reason: 'the picker failure must not escape');
    expect(tester.takeException(), isNull);
    expect(
      _snack(_s.mediaPickFailed),
      findsOneWidget,
      reason: 'the gallery would not open — name THAT',
    );
    expect(
      _snack(_s.avatarUploadFailed),
      findsNothing,
      reason:
          'nothing was uploaded, nothing was even picked: "photo upload '
          'failed" sends an admin who just declined the permission prompt off '
          'to check their internet',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'no upload was ever started',
    );
    expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);
  });

  testWidgets('an upload that fails after a successful pick still says '
      'avatarUploadFailed', (tester) async {
    // The other half of the pair: the picker DID open and the admin DID choose
    // a photo — it is the PUT that failed. That one is genuinely an upload
    // failure, and must keep saying so, so the fix above cannot degenerate
    // into "every avatar problem is a picker problem".
    final picked = File(
      '${Directory.systemTemp.path}/semay_edit_store_upload_fail_test.jpg',
    )..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
    addTearDown(picked.deleteSync);
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    const cropper = MethodChannel('plugins.hunghd.vn/image_cropper');
    final channels =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    channels.setMockMethodCallHandler(
      picker,
      (call) async => call.method == 'pickImage' ? picked.path : null,
    );
    channels.setMockMethodCallHandler(
      cropper,
      (call) async => call.method == 'cropImage' ? picked.path : null,
    );
    addTearDown(() {
      channels.setMockMethodCallHandler(picker, null);
      channels.setMockMethodCallHandler(cropper, null);
    });

    await _pump(tester, posts: _FailingUploads.new);
    await tester.runAsync(() async {
      await tester.tap(_avatarTap);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(_snack(_s.avatarUploadFailed), findsOneWidget);
    expect(_snack(_s.mediaPickFailed), findsNothing);
  });

  testWidgets(
    '400 INVALID_INPUT: a localised message, the screen stays, nothing escapes',
    (tester) async {
      final api = await _pump(tester);
      api.onPatch = (_, _) => throw ApiException(
        400,
        'INVALID_INPUT',
        body: {'error': 'INVALID_INPUT'},
      );
      await tester.enterText(_nameField, 'Audit Store 2');
      await tester.pump();

      expect(await _tapSaveGuarded(tester), isNull);
      expect(tester.takeException(), isNull);
      expect(api.calls, contains('PATCH /stores/$_storeId'));
      expect(_snack(_s.invalidInput), findsOneWidget);
      expect(find.byType(EditStoreScreen), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_save).onPressed,
        isNotNull,
        reason: 'can retry',
      );
    },
  );

  testWidgets('a request that never got an answer reads as noConnection', (
    tester,
  ) async {
    final api = await _pump(tester);
    api.onPatch = (_, _) => throw ApiException(null, 'REQUEST_FAILED');
    await tester.enterText(_nameField, 'Audit Store 2');
    await tester.pump();

    expect(await _tapSaveGuarded(tester), isNull);
    expect(tester.takeException(), isNull);
    expect(_snack(_s.noConnection), findsOneWidget);
    expect(find.byType(EditStoreScreen), findsOneWidget);
  });

  testWidgets('success pops and confirms on the screen it returns to', (
    tester,
  ) async {
    final api = await _pump(tester);
    Object? sent;
    api.onPatch = (_, body) {
      sent = body;
      return {
        'store': {..._store, 'name': 'Audit Store 2'},
      };
    };
    await tester.enterText(_nameField, 'Audit Store 2');
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect((sent as Map)['name'], 'Audit Store 2');
    expect(find.byType(EditStoreScreen), findsNothing, reason: 'popped');
    expect(
      _snack(_s.profileSaved),
      findsOneWidget,
      reason: 'the confirmation shows on the parent, after the pop',
    );
  });

  testWidgets(
    'backing out mid-save still refreshes the profile and still confirms',
    (tester) async {
      // The screen stays pop-able while the PATCH is in flight — only Save is
      // disabled — so an Android back gesture during a slow save is ordinary.
      // `ref.invalidate` on an unmounted State THROWS a StateError (riverpod's
      // _assertNotDisposed, live in release, not an assert), which landed in
      // the catch, whose body was gated on `mounted`. Net effect for a save
      // that SUCCEEDED: the store profile was never re-read and the admin was
      // never told, even though the messenger had been captured up front
      // precisely so it would survive the pop.
      var storeBuilds = 0;
      final api = await _pump(tester, onStoreDocBuild: () => storeBuilds++);
      final patch = Completer<Map<String, dynamic>>();
      api.onPatch = (_, _) => patch.future;
      await tester.enterText(_nameField, 'Audit Store 2');
      await tester.pump();

      await tester.tap(_save);
      await tester.pump();
      final buildsBeforePop = storeBuilds;

      // Back out while the PATCH is still in flight.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(EditStoreScreen), findsNothing, reason: 'popped');

      patch.complete({
        'store': {..._store, 'name': 'Audit Store 2'},
      });
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        storeBuilds,
        greaterThan(buildsBeforePop),
        reason: 'the store profile was re-read, so the new name shows',
      );
      expect(
        _snack(_s.profileSaved),
        findsOneWidget,
        reason: 'the save happened, so the admin must be told',
      );
    },
  );

  testWidgets('backing out mid-save still reports a FAILED save', (
    tester,
  ) async {
    final api = await _pump(tester);
    final patch = Completer<Map<String, dynamic>>();
    api.onPatch = (_, _) => patch.future;
    await tester.enterText(_nameField, 'Audit Store 2');
    await tester.pump();
    await tester.tap(_save);
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    patch.completeError(ApiException(null, 'REQUEST_FAILED'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      _snack(_s.noConnection),
      findsOneWidget,
      reason: 'silence would read as "saved"',
    );
  });

  testWidgets('address and phone cannot exceed the server\'s own limits', (
    tester,
  ) async {
    // updateStoreSchema: phone max(20), address max(255), tagline max(255).
    // Neither field had a cap, so a formatted phone ("+993 65 12-34-56 (call
    // after 9)") enabled Save, 400'd, and the admin got the generic "invalid
    // data" with nothing naming the field.
    await _pump(tester);
    final address = find.byType(TextField).at(2);
    final phone = find.byType(TextField).at(3);

    await tester.enterText(address, 'a' * 300);
    await tester.enterText(phone, '+993 65 12-34-56 (call after 9)');
    await tester.pump();

    expect(tester.widget<TextField>(address).controller!.text.length, 255);
    expect(tester.widget<TextField>(phone).controller!.text.length, 20);
  });

  testWidgets('an over-long name says why, instead of a dead Save button', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(_nameField, 'x' * 121);
    await tester.pump();

    expect(tester.widget<FilledButton>(_save).onPressed, isNull);
    expect(
      find.text(_s.nameTooLong(120)),
      findsOneWidget,
      reason: 'a disabled Save with no explanation is what was rejected',
    );
  });

  testWidgets('Save is withheld for an empty or over-long name', (
    tester,
  ) async {
    await _pump(tester);
    expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);

    await tester.enterText(_nameField, '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);

    await tester.enterText(_nameField, 'x' * 121);
    await tester.pump();
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);

    await tester.enterText(_nameField, 'x' * 120);
    await tester.pump();
    expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);
  });

  testWidgets('Save is withheld while the avatar upload is in flight', (
    tester,
  ) async {
    // The screen reads the cropped file back before uploading it, so the
    // picked path has to exist.
    final picked = File(
      '${Directory.systemTemp.path}/semay_edit_store_avatar_test.jpg',
    )..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
    addTearDown(picked.deleteSync);
    // Under `flutter test` the picker and cropper are the plain MethodChannel
    // implementations, so their channels can be answered directly.
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    const cropper = MethodChannel('plugins.hunghd.vn/image_cropper');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      picker,
      (call) async => call.method == 'pickImage' ? picked.path : null,
    );
    messenger.setMockMethodCallHandler(
      cropper,
      (call) async => call.method == 'cropImage' ? picked.path : null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(picker, null);
      messenger.setMockMethodCallHandler(cropper, null);
    });

    await _pump(tester, posts: _HangingUploads.new);
    expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);

    // Reading the picked file is real I/O, which only progresses in runAsync.
    await tester.runAsync(() async {
      await tester.tap(
        find
            .ancestor(
              of: find.byType(CircleAvatar).first,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: 'the upload overlay is up',
    );
    expect(
      tester.widget<FilledButton>(_save).onPressed,
      isNull,
      reason: 'Save would race the upload and send the old avatarUrl',
    );
  });
}
