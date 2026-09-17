// EditProfileScreen (user "Edit profile": PATCH /users/me through
// AuthService.completeProfile) used to confirm a save with the Save button's
// own label and report a failure as the raw ApiException string, and a first
// build that ran before GET /users/me resolved left the name field empty for
// the session. These drive the REAL screen with a scripted ApiClient.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/settings/edit_profile_screen.dart';

import '../support/fakes.dart';

// Turkmen: what a profile without a `language` renders in.
const _s = S(false);

Map<String, dynamic> _me(String name) => {
  'user': {
    'id': 'u1',
    'name': name,
    'phone': '+99363538839',
    'language': 'tk',
  },
};

Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Finder get _save => find.widgetWithText(FilledButton, _s.save);

String _nameFieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

Future<FakeApi> _pump(WidgetTester tester, {FakeApi? api}) async {
  api ??= FakeApi()..onGet = (_) => _me('Azim');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionControllerProvider.overrideWith(() => FakeSession()),
      ],
      child: const MaterialApp(home: EditProfileScreen()),
    ),
  );
  return api;
}

/// The same screen, but PUSHED over a parent Scaffold — the shape the app
/// actually runs in (Settings → Edit profile). That parent is what gives the
/// back-out tests below a BackButton to tap and somewhere for the outcome to
/// land after the pop; mirrors edit_store_feedback_test.dart's `_pump`.
Future<FakeApi> _pumpPushed(WidgetTester tester, {FakeApi? api}) async {
  api ??= FakeApi()..onGet = (_) => _me('Azim');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionControllerProvider.overrideWith(() => FakeSession()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const EditProfileScreen(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(EditProfileScreen), findsOneWidget);
  return api;
}

Future<void> _typeAndSave(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).first, name);
  await tester.pump();
  await tester.tap(_save);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('the name field fills in once the profile arrives', (
    tester,
  ) async {
    final profile = Completer<Map<String, dynamic>>();
    await _pump(tester, api: FakeApi()..onGet = (_) => profile.future);
    await tester.pump();
    // The first build ran with the profile still loading.
    expect(_nameFieldText(tester), '');

    profile.complete(_me('Azim'));
    await tester.pumpAndSettle();
    expect(_nameFieldText(tester), 'Azim');
    expect(
      tester.widget<FilledButton>(_save).onPressed,
      isNull,
      reason: 'nothing to save yet',
    );
  });

  testWidgets('a name typed while the profile is still loading is not clobbered', (
    tester,
  ) async {
    // The seed moved from "the first build" to "the first build with a
    // profile", and the field is live and focusable for that whole wait: a
    // cold start on a slow link let someone type, then had the resolving GET
    // silently replace their edit with the server's old name, cursor at 0.
    final profile = Completer<Map<String, dynamic>>();
    await _pump(tester, api: FakeApi()..onGet = (_) => profile.future);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Merdan');
    await tester.pump();

    profile.complete(_me('Azim'));
    await tester.pumpAndSettle();
    expect(_nameFieldText(tester), 'Merdan');
    expect(
      tester.widget<FilledButton>(_save).onPressed,
      isNotNull,
      reason: 'dirty against the saved name, which was still read',
    );
  });

  testWidgets('success confirms with profileSaved and re-reads /users/me', (
    tester,
  ) async {
    final api = await _pump(tester);
    api.onPatch = (_, _) => _me('Azim 2');
    await tester.pumpAndSettle();
    expect(api.count('GET /users/me'), 1);

    await _typeAndSave(tester, 'Azim 2');
    expect(_snack(_s.profileSaved), findsOneWidget);
    expect(_snack(_s.save), findsNothing, reason: 'not the button label');
    expect(api.calls, contains('PATCH /users/me'));
    expect(
      api.count('GET /users/me'),
      2,
      reason: 'userProfileProvider invalidated → refetched',
    );
    expect(
      tester.widget<FilledButton>(_save).onPressed,
      isNull,
      reason: 'the field now equals the saved name',
    );
  });

  testWidgets('400 INVALID_INPUT reads as invalidInput, not the raw exception', (
    tester,
  ) async {
    final api = await _pump(tester);
    api.onPatch = (_, _) => throw ApiException(
      400,
      'INVALID_INPUT',
      body: {'error': 'INVALID_INPUT'},
    );
    await tester.pumpAndSettle();

    await _typeAndSave(tester, 'Azim 2');
    expect(tester.takeException(), isNull);
    expect(_snack(_s.invalidInput), findsOneWidget);
    expect(find.textContaining('ApiException'), findsNothing);
    expect(
      tester.widget<FilledButton>(_save).onPressed,
      isNotNull,
      reason: 'still dirty, can retry',
    );
  });

  testWidgets('a request that never got an answer reads as noConnection', (
    tester,
  ) async {
    final api = await _pump(tester);
    api.onPatch = (_, _) => throw ApiException(null, 'REQUEST_FAILED');
    await tester.pumpAndSettle();

    await _typeAndSave(tester, 'Azim 2');
    expect(tester.takeException(), isNull);
    expect(_snack(_s.noConnection), findsOneWidget);
  });

  testWidgets('a 502 with no API error body reads as serverError, not noConnection', (
    tester,
  ) async {
    // _mapError falls back to REQUEST_FAILED for any response whose body is
    // not the API's {error} shape — an nginx 502/504 page, an empty 500. That
    // must not be reported as "no internet": the phone is fine, the server is
    // not, and the owner spent the outage toggling airplane mode.
    final api = await _pump(tester);
    api.onPatch = (_, _) => throw ApiException(502, 'REQUEST_FAILED');
    await tester.pumpAndSettle();

    await _typeAndSave(tester, 'Azim 2');
    expect(tester.takeException(), isNull);
    expect(_snack(_s.serverError), findsOneWidget);
    expect(_snack(_s.noConnection), findsNothing);
  });

  testWidgets('an over-long name is refused locally, without a request', (
    tester,
  ) async {
    final api = await _pump(tester);
    await tester.pumpAndSettle();

    await _typeAndSave(tester, 'x' * 121);
    expect(_snack(_s.nameTooLong(120)), findsOneWidget);
    expect(api.calls, isNot(contains('PATCH /users/me')));
  });

  testWidgets('a failed "change phone number" names the reason, never a raw code', (
    tester,
  ) async {
    // The other half of this screen. AuthService wraps everything the OTP
    // endpoints throw in an OtpException whose message, for anything that is
    // not an OTP-specific case, is the raw server code — so the red slot
    // showed the literal "REQUEST_FAILED" (before that, the whole
    // "ApiException(null, REQUEST_FAILED)").
    final api = await _pump(tester);
    api.onPost = (_, _) => throw ApiException(null, 'REQUEST_FAILED');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, _s.change));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '63538839');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _s.sendCode));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(api.calls, contains('POST /auth/otp/send'));
    expect(find.textContaining('REQUEST_FAILED'), findsNothing);
    expect(find.textContaining('ApiException'), findsNothing);
    final error = tester.widget<Text>(find.text(_s.noConnection));
    expect(error.style?.color, Colors.red, reason: 'the red error slot');
  });

  /// Drives the change-phone flow to the "enter the code" step.
  Future<void> toCodeStep(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, _s.change));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '63538839');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _s.sendCode));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a wrong code reads as the localised incorrectCode, not English', (
    tester,
  ) async {
    // The app ships Turkmen + Russian only. AuthService used to build three
    // OtpException messages as English PROSE ("Invalid code", "Please wait
    // 45s…", "That phone number is already in use") and this red slot renders
    // the message verbatim — so "Invalid code" sat directly above the Turkmen
    // "Galan synanyşyk: 3". Every OtpException now carries a server CODE and
    // describeOtpError localises it.
    final api = await _pump(tester);
    api.onPost = (path, _) {
      if (path == '/auth/change-phone') {
        throw ApiException(
          400,
          'OTP_INVALID',
          body: {'error': 'OTP_INVALID', 'attemptsRemaining': 3},
        );
      }
      return const {};
    };
    await tester.pumpAndSettle();
    await toCodeStep(tester);

    await tester.enterText(find.byType(TextField).at(1), '000000');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _s.verify));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Invalid code'), findsNothing);
    expect(find.textContaining('OTP_INVALID'), findsNothing);
    expect(
      tester.widget<Text>(find.text(_s.incorrectCode)).style?.color,
      Colors.red,
    );
    expect(find.text(_s.attemptsRemaining(3)), findsOneWidget);
  });

  testWidgets('a phone already in use is named, in the user\'s language', (
    tester,
  ) async {
    final api = await _pump(tester);
    api.onPost = (path, _) {
      if (path == '/auth/change-phone') {
        throw ApiException(409, 'PHONE_ALREADY_IN_USE');
      }
      return const {};
    };
    await tester.pumpAndSettle();
    await toCodeStep(tester);

    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _s.verify));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('already in use'), findsNothing);
    expect(
      tester.widget<Text>(find.text(_s.phoneAlreadyInUse)).style?.color,
      Colors.red,
    );
  });

  testWidgets('the resend cooldown is reported with its seconds, localised', (
    tester,
  ) async {
    // The other likely failure of this flow: a resend inside the server's
    // 60 s cooldown (OTP_RESEND_COOLDOWN_SECONDS).
    final api = await _pump(tester);
    api.onPost = (_, _) => throw ApiException(
      429,
      'OTP_COOLDOWN',
      body: {'error': 'OTP_COOLDOWN', 'retryAfterSeconds': 45},
    );
    await tester.pumpAndSettle();
    await toCodeStep(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Please wait'), findsNothing);
    expect(find.text(_s.waitBeforeNewCode(45)), findsOneWidget);
  });

  testWidgets('a 429 from the rate limiter is localised, not English prose', (
    tester,
  ) async {
    // fastify-rate-limit does NOT answer in the API's {error: "CODE"} shape —
    // its body is {error: "Too Many Requests", ...}. That reached the red slot
    // as English before, and must now go through the house copy like any
    // other status.
    final api = await _pump(tester);
    api.onPost = (_, _) => throw ApiException(
      429,
      'Too Many Requests',
      body: {'error': 'Too Many Requests'},
    );
    await tester.pumpAndSettle();
    await toCodeStep(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Too Many Requests'), findsNothing);
    expect(find.text(_s.tooManyRequests), findsOneWidget);
  });

  testWidgets('Save is disabled while the request is in flight', (
    tester,
  ) async {
    final api = await _pump(tester);
    final patch = Completer<Map<String, dynamic>>();
    api.onPatch = (_, _) => patch.future;
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Azim 2');
    await tester.pump();
    await tester.tap(_save);
    await tester.pump();
    final button = find.byType(FilledButton);
    expect(
      find.descendant(
        of: button,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    patch.complete(_me('Azim 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_snack(_s.profileSaved), findsOneWidget);
  });

  // --- Backing out while the save is still in flight -----------------------
  // Only Save is disabled during the PATCH: the AppBar back button, the
  // Android back gesture and the iOS edge swipe all stay live, and on a dead
  // link the request sits there for the full 15 s connect timeout. Both
  // SnackBars used to be gated on `mounted`, so an ordinary back tap in that
  // window made BOTH outcomes silent — and silence reads as "saved", because
  // Settings still shows the old name. The admin twin has pinned exactly this
  // since edit_store_feedback_test.dart:275/:321; this is the missing half.

  testWidgets('backing out mid-save still CONFIRMS a successful save', (
    tester,
  ) async {
    final api = await _pumpPushed(tester);
    final patch = Completer<Map<String, dynamic>>();
    api.onPatch = (_, _) => patch.future;
    await tester.enterText(find.byType(TextField).first, 'Azim 2');
    await tester.pump();
    await tester.tap(_save);
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(EditProfileScreen), findsNothing, reason: 'popped');

    patch.complete(_me('Azim 2'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      _snack(_s.profileSaved),
      findsOneWidget,
      reason: 'the save happened, so the user must be told',
    );
  });

  testWidgets('backing out mid-save still reports a FAILED save', (
    tester,
  ) async {
    final api = await _pumpPushed(tester);
    final patch = Completer<Map<String, dynamic>>();
    api.onPatch = (_, _) => patch.future;
    await tester.enterText(find.byType(TextField).first, 'Azim 2');
    await tester.pump();
    await tester.tap(_save);
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(EditProfileScreen), findsNothing, reason: 'popped');

    patch.completeError(ApiException(null, 'REQUEST_FAILED'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      _snack(_s.noConnection),
      findsOneWidget,
      reason: 'silence would read as "saved"',
    );
  });

  testWidgets('backing out mid-verify still confirms a changed phone number', (
    tester,
  ) async {
    // _verifyNewPhone had the identical shape, on the one change in this
    // screen that cannot be undone by retyping: the login identity.
    final api = await _pumpPushed(tester);
    final change = Completer<Map<String, dynamic>>();
    api.onPost = (path, _) =>
        path == '/auth/change-phone' ? change.future : const {};
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, _s.change));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '63538839');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _s.sendCode));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _s.verify));
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(EditProfileScreen), findsNothing, reason: 'popped');

    change.complete(const {});
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_snack(_s.profileSaved), findsOneWidget);
  });
}
