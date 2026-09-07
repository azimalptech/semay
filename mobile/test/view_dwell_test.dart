// The one dwell rule behind every view count (feed card, image detail, reel
// player) — see lib/features/shared/view_dwell.dart. testWidgets rather than
// test: its FakeAsync zone is what lets tester.pump drive the Timer.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/features/shared/view_dwell.dart';

void main() {
  testWidgets('counts 0.8 s after start, once', (tester) async {
    var views = 0;
    final dwell = ViewDwell(() => views++, inForeground: true);

    dwell.start();
    await tester.pump(const Duration(milliseconds: 700));
    expect(views, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(views, 1);

    // Back on screen after recording: this instance is done.
    dwell.start();
    await tester.pump(const Duration(seconds: 2));
    expect(views, 1);
  });

  testWidgets('leaving before the threshold cancels; the next dwell starts '
      'from zero', (tester) async {
    var views = 0;
    final dwell = ViewDwell(() => views++, inForeground: true);

    dwell.start();
    await tester.pump(const Duration(milliseconds: 500));
    dwell.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(views, 0);

    dwell.start();
    await tester.pump(const Duration(milliseconds: 500));
    expect(views, 0, reason: 'the 500 ms before the cancel does not carry over');
    await tester.pump(const Duration(milliseconds: 300));
    expect(views, 1);
  });

  testWidgets('an explicit signal counts immediately and disarms the timer', (
    tester,
  ) async {
    var views = 0;
    final dwell = ViewDwell(() => views++, inForeground: true);

    dwell.start();
    dwell.record();
    expect(views, 1);
    await tester.pump(const Duration(seconds: 1));
    dwell.record();
    expect(views, 1);
  });

  testWidgets('the app leaving the foreground cancels a running dwell; '
      'coming back starts it over', (tester) async {
    var views = 0;
    final dwell = ViewDwell(() => views++, inForeground: true);

    dwell.start();
    await tester.pump(const Duration(milliseconds: 500));
    dwell.inForeground = false;
    await tester.pump(const Duration(seconds: 2));
    expect(views, 0, reason: 'locked the screen at 0.5 s: not a view');

    dwell.inForeground = true;
    await tester.pump(const Duration(milliseconds: 700));
    expect(views, 0, reason: 'the 500 ms from before does not carry over');
    await tester.pump(const Duration(milliseconds: 100));
    expect(views, 1);
  });

  testWidgets('returning to the foreground arms nothing for a surface that '
      'went off screen meanwhile, and a surface shown while away counts only '
      'once the app is back', (tester) async {
    var views = 0;
    final dwell = ViewDwell(() => views++, inForeground: true);

    dwell.start();
    dwell.inForeground = false;
    dwell.cancel();
    dwell.inForeground = true;
    await tester.pump(const Duration(seconds: 2));
    expect(views, 0);

    final shownWhileAway = ViewDwell(() => views++, inForeground: false);
    shownWhileAway.start();
    await tester.pump(const Duration(seconds: 2));
    expect(views, 0);
    shownWhileAway.inForeground = true;
    await tester.pump(const Duration(milliseconds: 800));
    expect(views, 1);
  });
}
