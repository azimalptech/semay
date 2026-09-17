// The language row on Settings opens a modal bottom sheet, and the sheet
// PATCHes /users/me. A change that cannot reach the server did report itself —
// but on the ROOT ScaffoldMessenger, which paints the SnackBar into the
// settings Scaffold UNDERNEATH the still-open sheet and its barrier. Reported,
// never seen: the same "silent save" the rest of this pass exists to remove.
// These drive the REAL SettingsScreen with a scripted ApiClient.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/settings/settings_screen.dart';

import '../support/fakes.dart';

// Turkmen: what a profile without a `language` renders in.
const _s = S(false);

const _me = <String, dynamic>{
  'user': {
    'id': 'u1',
    'name': 'Azim',
    'phone': '+99363538839',
    'language': 'tk',
    'darkMode': false,
  },
};

Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

/// The sheet's own header — present only while the sheet route is up.
Finder get _sheet => find.text(_s.selectLanguage);

/// SettingsScreen's cards wrap their ListTiles in a DecoratedBox, which trips
/// a debug-only cosmetic assertion ("ListTile background color or ink splashes
/// may be invisible") once per tile on every pump. It is unrelated to anything
/// tested here and pre-dates this pass — swallowed by name so these tests can
/// still assert that nothing ELSE was thrown.
void _ignoreListTileInkAssertion() {
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains(
      'ListTile background color or ink splashes may be invisible',
    )) {
      return;
    }
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

Future<FakeApi> _pump(WidgetTester tester) async {
  _ignoreListTileInkAssertion();
  final api = FakeApi()..onGet = (_) => _me;
  // A phone-shaped surface: the default 800x600 test view is shorter than the
  // settings list, and the language row would never be built.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionControllerProvider.overrideWith(() => FakeSession()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

/// Opens the sheet and picks Russian (the row that is not already selected).
Future<void> _pickRussian(WidgetTester tester) async {
  await tester.tap(find.text(_s.language));
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget, reason: 'the sheet is up');
  await tester.tap(find.text('Русский'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('a language change that cannot reach the server is SEEN, not '
      'painted behind the sheet', (tester) async {
    final api = await _pump(tester);
    api.onPatch = (_, _) => throw ApiException(null, 'REQUEST_FAILED');

    await _pickRussian(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(api.calls, contains('PATCH /users/me'));
    expect(_snack(_s.noConnection), findsOneWidget);
    expect(
      _sheet,
      findsNothing,
      reason:
          'the sheet must come down first — the root messenger paints the '
          'SnackBar into the Scaffold underneath it, so with the sheet still '
          'up the failure is drawn behind the sheet and its barrier',
    );
  });

  testWidgets('the failure is reported even if the sheet is closed first', (
    tester,
  ) async {
    // The other order: the user taps Русский and dismisses the sheet while the
    // PATCH is still in flight. The pop must not be attempted twice (that
    // would take the settings screen with it) and the message must still land.
    final api = await _pump(tester);
    final patch = Completer<Map<String, dynamic>>();
    api.onPatch = (_, _) => patch.future;

    await tester.tap(find.text(_s.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Русский'));
    await tester.pump();

    // Dismiss the sheet by tapping its own close button.
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);

    patch.completeError(ApiException(null, 'REQUEST_FAILED'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_snack(_s.noConnection), findsOneWidget);
    expect(
      find.byType(SettingsScreen),
      findsOneWidget,
      reason: 'a second pop would have taken the settings screen down',
    );
  });

  testWidgets('a successful change closes the sheet and sends the language', (
    tester,
  ) async {
    final api = await _pump(tester);
    Object? sent;
    api.onPatch = (_, body) {
      sent = body;
      return const {};
    };

    await _pickRussian(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect((sent as Map)['language'], 'ru');
    expect(_sheet, findsNothing);
    expect(_snack(_s.noConnection), findsNothing);
  });
}
