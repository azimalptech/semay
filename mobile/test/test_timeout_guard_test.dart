// A suite-health guard, not a product test.
//
// test/flutter_test_config.dart caps every test at two minutes because
// flutter_test ignores `--timeout` and defaults to ten (see that file). If the
// config is deleted, renamed or stops being picked up, the only symptom is
// that the next wedged test costs ten minutes again — invisible until someone
// tries to run the suite. This turns that into a failing assertion.

import 'package:flutter_test/flutter_test.dart';

import 'flutter_test_config.dart' show kSemayTestTimeout;

void main() {
  test('flutter_test_config caps every test at two minutes', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    expect(binding, isA<AutomatedTestWidgetsFlutterBinding>());
    expect(
      binding.defaultTestTimeout,
      kSemayTestTimeout,
      reason:
          'test/flutter_test_config.dart did not run; a hung test would once '
          'again hold the whole suite for ten minutes',
    );
    expect(kSemayTestTimeout, const Timeout(Duration(minutes: 2)));
  });
}
