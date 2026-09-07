// ShellTabPager's settled-tab publisher is what every video player gates
// on (see lib/core/shell_tab.dart). These pin the cases the previous
// VisibilityDetector gating got wrong: a Reels page built mid-transit must
// never read as settled, and a page route over the shell must un-settle it
// while a dialog must not.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/shell_tab.dart';

// router.dart _goToPage(): animateToPage(index, 280ms, easeOut).
const _tabAnimation = Duration(milliseconds: 280);

/// Stands in for ReelsScreen: records every value it was built with.
class _ReelsProbe extends ConsumerWidget {
  const _ReelsProbe({required this.settledSeen});

  final List<bool> settledSeen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    settledSeen.add(ref.watch(reelsTabSettledProvider));
    return const ColoredBox(color: Colors.black);
  }
}

class _Harness {
  _Harness(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;
  final history = <int?>[];
  final reelsSettledSeen = <bool>[];
  late PageController controller;

  int? get settled => container.read(settledShellTabProvider);
  bool get reelsSettled => container.read(reelsTabSettledProvider);

  Future<void> mountShell({Key? key}) async {
    controller = PageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [shellRouteObserver],
          home: Scaffold(
            body: ShellTabPager(
              key: key,
              controller: controller,
              pages: [
                const Center(child: Text('home')),
                _ReelsProbe(settledSeen: reelsSettledSeen),
                const Center(child: Text('leaderboard')),
                const Center(child: Text('chat')),
                const Center(child: Text('profile')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> goToTab(int index) async {
    controller.animateToPage(
      index,
      duration: _tabAnimation,
      curve: Curves.easeOut,
    );
    await tester.pumpAndSettle();
  }
}

void _shellTest(
  String description,
  Future<void> Function(WidgetTester tester, _Harness h) body,
) {
  testWidgets(description, (tester) async {
    final container = ProviderContainer();
    final h = _Harness(tester, container);
    container.listen(settledShellTabProvider, (_, next) => h.history.add(next));
    await h.mountShell();

    await body(tester, h);

    // Before flutter_test's own teardown: take the tree down, then dispose
    // the container — that cancels Riverpod's zero-length refresh timer
    // from the last state change, which would otherwise trip the
    // no-pending-timers check.
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}

void main() {
  _shellTest('cold start settles on Home; Reels is not even built', (
    tester,
    h,
  ) async {
    expect(h.settled, 0);
    expect(h.reelsSettled, isFalse);
    expect(find.byType(_ReelsProbe, skipOffstage: false), findsNothing);
  });

  _shellTest('a tab tap that passes through Reels builds it but never '
      'settles it', (tester, h) async {
    await h.goToTab(3);

    expect(find.byType(_ReelsProbe, skipOffstage: false), findsOneWidget);
    expect(h.reelsSettledSeen, isNot(contains(true)));
    expect(h.history, isNot(contains(kReelsTabIndex)));
    expect(h.settled, 3);
  });

  _shellTest('Reels settles only once the pager comes to rest on it, and '
      'un-settles on the way back', (tester, h) async {
    h.controller.animateToPage(
      kReelsTabIndex,
      duration: _tabAnimation,
      curve: Curves.easeOut,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(h.settled, isNull, reason: 'past the 50% crossing, still moving');
    expect(h.reelsSettledSeen, isNot(contains(true)));

    await tester.pumpAndSettle();
    expect(h.reelsSettled, isTrue);
    expect(h.reelsSettledSeen.last, isTrue);

    await h.goToTab(0);
    expect(h.settled, 0);
    expect(h.reelsSettled, isFalse);
  });

  _shellTest('a page route over the shell un-settles Reels; popping it '
      'settles again', (tester, h) async {
    h.controller.jumpToPage(kReelsTabIndex);
    await tester.pumpAndSettle();
    expect(h.reelsSettled, isTrue);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('store profile')),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.settled, isNull);
    expect(h.reelsSettled, isFalse);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(h.settled, kReelsTabIndex);
    expect(h.reelsSettled, isTrue);
  });

  _shellTest('a dialog over Reels leaves it settled', (tester, h) async {
    h.controller.jumpToPage(kReelsTabIndex);
    await tester.pumpAndSettle();

    showDialog<void>(
      context: tester.element(find.byType(_ReelsProbe)),
      builder: (_) => const AlertDialog(title: Text('Delete post?')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete post?'), findsOneWidget);
    expect(h.reelsSettled, isTrue);
  });

  _shellTest('a page route pushed while a dialog is open still covers Reels; '
      'popping it settles Reels again under the dialog', (tester, h) async {
    h.controller.jumpToPage(kReelsTabIndex);
    await tester.pumpAndSettle();
    showDialog<void>(
      context: tester.element(find.byType(_ReelsProbe)),
      builder: (_) => const AlertDialog(title: Text('Delete post?')),
    );
    await tester.pumpAndSettle();
    expect(h.reelsSettled, isTrue);

    // What a chat notification tap does from wherever the user is.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('chat thread')),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.settled, isNull);
    expect(h.reelsSettled, isFalse);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Delete post?'), findsOneWidget);
    expect(h.settled, kReelsTabIndex);
    expect(h.reelsSettled, isTrue);
  });

  _shellTest('a finger landing mid-animation holds the pager at a fraction: '
      'not settled until it snaps to a whole page', (tester, h) async {
    h.controller.animateToPage(
      kReelsTabIndex,
      duration: _tabAnimation,
      curve: Curves.easeOut,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await tester.pump();
    final page = h.controller.page!;
    expect((page - page.round()).abs(), greaterThan(0.05));
    expect(h.settled, isNull);
    expect(h.history, isNot(contains(kReelsTabIndex)));
    expect(h.reelsSettledSeen, isNot(contains(true)));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(h.settled, kReelsTabIndex);
    expect(h.reelsSettled, isTrue);
  });

  _shellTest('a replacement shell publishes its own tab on its first frame', (
    tester,
    h,
  ) async {
    h.controller.jumpToPage(kReelsTabIndex);
    await tester.pumpAndSettle();
    expect(h.settled, kReelsTabIndex);

    // Old pager disposed and new one mounted in the same frame — what a
    // dark-mode toggle does to the whole MaterialApp.
    await h.mountShell(key: UniqueKey());
    expect(h.settled, 0);
  });

  test('appInForegroundProvider starts true and follows set()', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(appInForegroundProvider), isTrue);
    container.read(appInForegroundProvider.notifier).set(false);
    expect(container.read(appInForegroundProvider), isFalse);
  });
}
