import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Figma-defined order for both roles' MenuBar2: home, play-square (Reels),
// trophy-star (Leaderboard), send (Chat), user (Profile).
const kReelsTabIndex = 1;
const kChatTabIndex = 3;

/// Which bottom-nav tab is the settled, uncovered one — the single answer
/// every video player gates playback on. `null` while the shell pager is
/// moving and while a page route sits over the shell, so "not settled" and
/// "not showing" are the same thing. Null before the first shell mounts too;
/// after a shell goes away the last value simply stays until the next shell
/// publishes on its first frame (a dark-mode toggle, a role redirect) — no
/// consumer exists outside a shell, so nothing can read it stale.
///
/// Exists because a kept-alive PageView page can't tell on its own whether
/// it is showing: VisibilityDetector never reports "hidden" for a page that
/// was built mid-transit (a Home -> Chat tap scrolls straight through Reels)
/// and never got a "visible" first, so a reel built that way used to start
/// its audio behind another tab. The pager publishing its own state has no
/// such blind spot, and no 500 ms reporting lag either.
class SettledShellTab extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? index) => state = index;
}

final settledShellTabProvider = NotifierProvider<SettledShellTab, int?>(
  SettledShellTab.new,
);

final reelsTabSettledProvider = Provider<bool>(
  (ref) => ref.watch(settledShellTabProvider) == kReelsTabIndex,
);

/// False while the OS has the app off screen — `paused`, `hidden`,
/// `detached` — and true again on `resumed`. `inactive` still counts as on
/// screen: the app is showing under a pulled-down notification shade, a
/// permission prompt or iOS control centre, and the rule is "pauses when
/// backgrounded", nothing broader. video_player's Android and iOS plugins
/// carry on playing through a background on their own, so every player
/// pauses on this flag instead. Written only by main.dart's
/// AppLifecycleListener.
class AppForeground extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool inForeground) => state = inForeground;
}

final appInForegroundProvider = NotifierProvider<AppForeground, bool>(
  AppForeground.new,
);

/// Registered on the GoRouter so [ShellTabPager] hears page routes pushed
/// over (and taken off) the shell. PageRoute, not ModalRoute, on purpose:
/// dialogs and bottom sheets are PopupRoutes and don't count as covering, so
/// a reel keeps playing behind the send-to-chat sheet as it always has.
final shellRouteObserver = _ShellRouteObserver();

class _ShellRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  // RouteObserver relays a push or pop to the route beneath only when both
  // are PageRoutes. With a popup in between — confirm-delete open over
  // Reels, then a chat notification tap pushing the thread — the shell never
  // heard it was covered and the reel played on under the chat. This mirror
  // of the navigator's stack finds the page route under the popup, so that
  // push and its pop reach the shell like any other.
  final _stack = <Route<dynamic>>[];

  Route<dynamic>? _pageRouteUnder(Route<dynamic>? previousRoute) {
    if (previousRoute == null || previousRoute is PageRoute<dynamic>) {
      return previousRoute;
    }
    for (var i = _stack.indexOf(previousRoute) - 1; i >= 0; i--) {
      if (_stack[i] is PageRoute<dynamic>) return _stack[i];
    }
    return null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Nothing beneath: the navigator started over, and whatever the mirror
    // still holds is gone.
    if (previousRoute == null) _stack.clear();
    _stack.add(route);
    super.didPush(route, _pageRouteUnder(previousRoute));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    super.didPop(route, _pageRouteUnder(previousRoute));
  }

  // go_router's go() drops the pages above its target instead of popping
  // them, which reaches observers as didRemove — RouteObserver ignores that
  // and would leave the shell marked as covered for good.
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      didPop(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (at >= 0) _stack.removeAt(at);
    if (newRoute != null) _stack.insert(at < 0 ? _stack.length : at, newRoute);
  }
}

/// Marks which shell tab a subtree belongs to, so a widget deep inside a
/// tab (a feed reel tile) can compare against [settledShellTabProvider]
/// without knowing where it was mounted. Absent outside the shell — the
/// store's and search's post pagers are pushed routes.
class ShellTabScope extends InheritedWidget {
  const ShellTabScope({super.key, required this.index, required super.child});

  final int index;

  static int? maybeIndexOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTabScope>()?.index;

  @override
  bool updateShouldNotify(ShellTabScope oldWidget) => index != oldWidget.index;
}

/// The shell's horizontal tab pager, and the one writer of
/// [settledShellTabProvider]. router.dart's _SwipeableTabShell keeps the
/// PageController (its nav bar cross-fades off the live position) and the
/// nav-bar/PopScope state; this decides what "settled" means:
///  * a tab is settled when the pager's own ScrollEndNotification arrives
///    (depth 0 — a nested feed list or the reels' vertical pager doesn't
///    count) with the pager on a whole page, not on onPageChanged, which
///    fires at the 50% crossing and, for a tap that jumps several tabs, for
///    the pages passed on the way;
///  * onPageChanged does mark the pager as moving (null), so nothing plays
///    mid-swipe;
///  * a PageRoute pushed over the shell covers it (null) until it is gone.
class ShellTabPager extends ConsumerStatefulWidget {
  const ShellTabPager({
    super.key,
    required this.controller,
    required this.pages,
    this.onPageChanged,
  });

  final PageController controller;
  final List<Widget> pages;
  final ValueChanged<int>? onPageChanged;

  @override
  ConsumerState<ShellTabPager> createState() => _ShellTabPagerState();
}

class _ShellTabPagerState extends ConsumerState<ShellTabPager>
    with RouteAware {
  late int _settled = widget.controller.initialPage;
  bool _covered = false;
  bool _publishScheduled = false;

  @override
  void initState() {
    super.initState();
    _publishAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    shellRouteObserver.subscribe(this, ModalRoute.of(context)! as PageRoute);
  }

  @override
  void dispose() {
    shellRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() {
    _covered = true;
    _publishAfterFrame();
  }

  @override
  void didPopNext() {
    _covered = false;
    _publishAfterFrame();
  }

  SettledShellTab get _tab => ref.read(settledShellTabProvider.notifier);

  void _publish() => _tab.set(_covered ? null : _settled);

  // Route callbacks arrive from the Navigator's own build (go_router pushes
  // by rebuilding its pages list), where Riverpod forbids provider writes;
  // the first publish comes from initState for the same reason. The fields
  // are read when the callback runs, so a push and a pop inside one frame
  // land on the final answer.
  void _publishAfterFrame() {
    if (_publishScheduled) return;
    _publishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _publishScheduled = false;
      if (mounted) _publish();
    });
  }

  void _onScrollEnd() {
    // A finger landing mid-animation ends the scroll too — the pager is
    // held, not moving — but at a fraction of a page it can still be dragged
    // anywhere, so that is not rest. The snap after the release ends the
    // scroll again, on a whole page (the 1e-3 covers the spring's settle
    // tolerance).
    final page = widget.controller.page!;
    final rounded = page.round();
    if ((page - rounded).abs() > 1e-3) {
      _tab.set(null);
      return;
    }
    _settled = rounded;
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _onScrollEnd();
        return false;
      },
      child: PageView(
        controller: widget.controller,
        onPageChanged: (index) {
          // Moving — this may be a tab passed through on the way elsewhere.
          _tab.set(null);
          widget.onPageChanged?.call(index);
        },
        children: [
          for (var i = 0; i < widget.pages.length; i++)
            ShellTabScope(
              index: i,
              child: _KeepAlivePage(child: widget.pages[i]),
            ),
        ],
      ),
    );
  }
}

/// Keeps a tab's whole widget subtree alive once built — including scroll
/// position and any live VideoPlayerControllers — for as long as it stays
/// in the PageView's children list, same guarantee IndexedStack gave every
/// branch before.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
