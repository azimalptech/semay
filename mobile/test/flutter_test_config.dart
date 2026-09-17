// Loaded automatically by `flutter test` for every file under test/.
//
// Why it exists: flutter_test does NOT honour `--timeout`. testWidgets passes
// `binding.defaultTestTimeout` to package:test, and for
// AutomatedTestWidgetsFlutterBinding that field is a hard-coded 10 minutes
// (flutter_test/lib/src/binding.dart), so a command-line `--timeout 20s` is
// ignored and ANY wedged test costs ten minutes of wall clock. That is what
// made this suite unrunnable: two tests that awaited a Future completed in the
// root zone (a StreamSubscription.cancel() inside testWidgets — see
// test/core/realtime_client_liveness_test.dart's `_drop`) took twenty minutes
// between them and nobody could finish a run.
//
// The whole suite is ~15 s for 139 tests, so two minutes is not a budget any
// healthy test can reach — it is purely a ceiling on how long a NEW mistake of
// that shape can hold the run hostage. It is not a way to make a slow test
// pass: nothing here weakens an assertion.
//
// Set `Timeout.none` locally when stepping through a test in a debugger.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// The ceiling any one test may take. Asserted by
/// test/test_timeout_guard_test.dart so deleting this file is a failing test
/// rather than a silent return to ten-minute hangs.
const kSemayTestTimeout = Timeout(Duration(minutes: 2));

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    binding.defaultTestTimeout = kSemayTestTimeout;
  }
  await testMain();
}
