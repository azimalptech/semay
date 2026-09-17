import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_icon.dart';
import 'share_links.dart';
import 'shell_tab.dart';
import 'theme.dart';
import '../features/auth/name_entry_screen.dart';
import '../features/auth/otp_screen.dart';
import '../features/auth/phone_entry_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_providers.dart';
import '../features/chat/chat_thread_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/leaderboard/leaderboard_screen.dart';
import '../features/profile/liked_screen.dart';
import '../features/settings/edit_profile_screen.dart';
import '../features/profile/profile_notifications_screen.dart';
import '../features/reels/reels_screen.dart';
import '../features/search/search_pager_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/notification_request_screen.dart';
import '../features/settings/quick_replies_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shared/post_detail_screen.dart';
import '../features/store_admin/admin_home_screen.dart';
import '../features/store_admin/admin_profile_screen.dart';
import '../features/store_admin/edit_store_screen.dart';
import '../features/store_admin/my_store_screen.dart';
import '../features/store_admin/orders_screen.dart';
import '../features/store_profile/store_profile_screen.dart';
import '../features/story_viewer/story_viewer_screen.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';

// The 5-tab bottom nav (Figma frame 195:4299 "MenuBar2" / 223:4759 for
// Store Admin) is a single route per role hosting a swipeable PageView
// internally (_SwipeableTabShell) rather than 5 separate GoRouter routes —
// see that class for why. These are the only two shell-root paths left.
const _userShellRoot = '/home';
const _adminShellRoot = '/admin/home';
const _splashRoute = '/splash';

// Bridges Riverpod's reactive auth/role/profile providers into GoRouter's
// refreshListenable — this re-runs `redirect` for the *current* location
// whenever any of them change, without touching navigation state. Wiring
// these via ref.watch() on the provider itself (the previous approach)
// instead rebuilds the whole GoRouter object on every emission — including
// on every Firestore write to users/{uid}, e.g. saving your name — which
// resets navigation back to initialLocation and bounces you to Home from
// wherever you were.
class _RouterRefreshNotifier extends ChangeNotifier {
  _RouterRefreshNotifier(Ref ref) {
    ref.listen(authStateChangesProvider, (_, _) => notifyListeners());
    ref.listen(appRoleProvider, (_, _) => notifyListeners());
    ref.listen(userProfileProvider, (_, _) => notifyListeners());
  }
}

/// Sees a share link delivered to a RUNNING app before go_router's own
/// RouteInformationProvider does, so the link can be pushed onto the existing
/// navigation stack instead of replacing it — see handleWarmLink below.
/// Returning true from [didPushRouteInformation] stops WidgetsBinding handing
/// the route to any later observer.
class _WarmDeepLinkObserver extends WidgetsBindingObserver {
  _WarmDeepLinkObserver(this.handle);

  final bool Function(Uri uri) handle;

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async =>
      handle(routeInformation.uri);
}

// Role-based redirect: unauthenticated -> /auth/phone; authenticated with an
// incomplete profile (empty users/{uid}.name, set by verifyOtp) -> /auth/name;
// otherwise -> /home (user) or /admin/home (admin/superadmin).
final routerProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _RouterRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  // Set once auth state has resolved successfully the first time. Without
  // this, a transient re-loading blip in authStateChangesProvider (observed
  // on cold start — authState.hasValue briefly flips false again *after*
  // redirect() had already resolved all the way to /admin/home or /home)
  // sent the router straight back to /splash and then forward again,
  // visibly flashing the logo a second time. Splash is only ever a valid
  // *first* gate, never something to return to once passed.
  var pastInitialAuthResolve = false;

  // A share link the app was opened with (share_links.dart), parked by
  // redirect() until the shell root is the current location and then pushed
  // on top of it — so the linked post/store always has the shell (and a
  // working back) underneath, on a cold start, a warm one, and a cold start
  // that first has to go through login. A plain field rather than a
  // provider: on a cold start redirect() runs inside Router's
  // didChangeDependencies, where Riverpod forbids provider writes.
  ShareTarget? pendingDeepLink;
  late final GoRouter router;

  void dispatchPendingDeepLink() {
    final target = pendingDeepLink;
    if (target == null) return;
    final loc = router.routerDelegate.currentConfiguration.uri.path;
    if (loc != _userShellRoot && loc != _adminShellRoot) return;
    pendingDeepLink = null;
    debugPrint('router: opening deep link $target');
    router.push(target.route);
  }

  // Deferred, never inline: this is called from redirect() and from the
  // delegate's own change notification, and the check has to see the
  // location the navigation being processed ends on. The redirect chain is
  // synchronous, so a microtask runs once it has settled.
  void scheduleDeepLinkDispatch() =>
      Future<void>.microtask(dispatchPendingDeepLink);

  // A link that arrives while the app is ALREADY RUNNING (Android
  // onNewIntent, iOS openURL) is handled here and never handed to go_router.
  //
  // Not a refinement — a correctness fix. The platform delivers it as a new
  // route, and Router answers with setNewRoutePath, which REPLACES the whole
  // configuration: a user reading a chat, or three screens deep in a store,
  // who taps a SeMay link in WhatsApp had every one of those screens silently
  // discarded, because the stack was rebuilt from the shell root before the
  // linked screen was pushed on top. Returning the current location from
  // redirect() does not help; the replace happens either way. WhatsApp and
  // Instagram push over your current place and back returns to it, so this
  // pushes onto the live stack instead.
  //
  // Only the WARM case is intercepted. A cold start arrives as the engine's
  // initial route (not this channel), where there is no stack to preserve and
  // the parking path in redirect() below is what puts the shell underneath.
  bool handleWarmLink(Uri uri) {
    final target = parseIncomingLink(uri);
    if (target == null) {
      // A URI the app CLAIMS from the OS but cannot make a target out of —
      // `/p/` alone, `/p/<id>/extra`, a link with trailing prose
      // punctuation, a non-UUID id, `semay://open/x/<id>`. The manifest's
      // pathPrefix and the scheme filter claim a far wider space than
      // parseIncomingLink accepts (see isOwnShareUri), and once App Links
      // verify Android delivers all of it here with no chooser.
      //
      // Swallow it. Falling through to go_router is what reset the stack —
      // Router answers with setNewRoutePath, REPLACES the whole
      // configuration, matches nothing, and leaves the user on the default
      // "Page Not Found" screen with an EMPTY stack: no AppBar, no back, no
      // shell. A mangled link must cost nothing, not three screens.
      if (isOwnShareUri(uri)) {
        debugPrint('router: ignoring unparseable SeMay link $uri');
        return true;
      }
      // Genuinely foreign route information still belongs to go_router.
      return false;
    }
    final loc = router.routerDelegate.currentConfiguration.uri.path;
    // Still on the way in (splash, or the login flow): park it and let the
    // gates dispatch it once they land on a shell, exactly as a cold start
    // behind login does.
    if (loc == _splashRoute || loc.startsWith('/auth')) {
      pendingDeepLink = target;
      scheduleDeepLinkDispatch();
      return true;
    }
    debugPrint('router: warm deep link $target onto $loc');
    router.push(target.route);
    // Consumed either way: letting it fall through to go_router is what reset
    // the stack.
    return true;
  }

  final deepLinkObserver = _WarmDeepLinkObserver(handleWarmLink);
  // Added before the Router widget's own RouteInformationProvider registers
  // itself (that happens in Router.initState, after this provider is first
  // read), and WidgetsBinding hands a pushed route to observers in order,
  // stopping at the first that returns true — so this one sees warm links
  // first. Removed with the provider.
  WidgetsBinding.instance.addObserver(deepLinkObserver);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(deepLinkObserver));

  router = GoRouter(
    // Set once here, not created fresh per GoRouter instance — the same
    // "global key wired up before runApp, used by code with no
    // BuildContext of its own" pattern rootNavigatorKey's own doc comment
    // describes. This is what lets a notification tap (notification_service
    // .dart) call GoRouter.of(context) from outside the widget tree entirely.
    navigatorKey: rootNavigatorKey,
    // Tells the tab shell when a page route covers it — see shell_tab.dart.
    observers: [shellRouteObserver],
    initialLocation: _splashRoute,
    refreshListenable: refreshNotifier,
    // An unmatched location must never be a resting place. Without this,
    // go_router's built-in "Page Not Found" screen is the whole app: an
    // empty stack, no AppBar, no back, no shell — on Android the only way
    // out is to kill the app. Reachable on a COLD start from any URL the
    // AndroidManifest claims but share_links.dart cannot parse
    // (https://semaycollection.com/p/ and friends — see handleWarmLink,
    // which covers the warm half); redirect() returns null for those, so the
    // router would simply come to rest on the unmatched path.
    //
    // Land on the shell instead, exactly as a plain launch does. Same
    // `role.value != AppRole.user` test redirect() uses, for the same reason
    // it reads the role once: the two must not disagree about "admin".
    onException: (context, state, goRouter) {
      final isAdminRole = ref.read(appRoleProvider).value != AppRole.user;
      final home = isAdminRole ? _adminShellRoot : _userShellRoot;
      debugPrint('router: no route for ${state.uri} — falling back to $home');
      goRouter.go(home);
    },
    redirect: (context, state) {
      final authState = ref.read(authStateChangesProvider);
      final role = ref.read(appRoleProvider);
      final profile = ref.read(userProfileProvider);

      final loc = state.matchedLocation;
      debugPrint(
        'router: redirect() loc=$loc matchedLocation=${state.matchedLocation} '
        'uri=${state.uri} fullPath=${state.fullPath}',
      );

      // Read once and used by BOTH the deep-link shell choice below and the
      // role gate further down. They used to test the role two different ways
      // (`== admin || == superadmin` here, `!= user` there), which disagree
      // for AppRole.unauthenticated and for a null value after a failed role
      // fetch — only the synchronous redirect chain hid the disagreement.
      final isAdminRole = role.value != AppRole.user;

      // https://semaycollection.com/p/<id>, semay://open/s/<id>, … — the OS
      // handed us a share link. On a COLD start it arrives here as the initial
      // route (a warm one is intercepted before go_router sees it — see
      // handleWarmLink). Never a resting location: park it (see
      // pendingDeepLink) and send the router through its normal gates; the
      // linked screen is pushed once those land on the shell.
      final deepLink = parseIncomingLink(state.uri);
      if (deepLink != null) {
        pendingDeepLink = deepLink;
        scheduleDeepLinkDispatch();
      }
      // Where a link's own path goes wherever the gates below would otherwise
      // stay put — plain navigation keeps the `null` those branches return.
      String? stay() {
        if (deepLink == null) return null;
        if (!authState.hasValue && !pastInitialAuthResolve) return _splashRoute;
        if (authState.hasValue && authState.value == null) return '/auth/phone';
        return isAdminRole ? _adminShellRoot : _userShellRoot;
      }

      // Firebase Auth hasn't finished checking for a persisted session yet
      // (authStateChangesProvider's first, async emission) — stay on the
      // splash screen instead of flashing the login screen for an instant
      // before bouncing an already-signed-in user straight back out of it.
      // Only applies before the very first successful resolve — see
      // pastInitialAuthResolve's comment above.
      if (!authState.hasValue) {
        if (pastInitialAuthResolve) return stay();
        return loc == _splashRoute ? null : _splashRoute;
      }
      pastInitialAuthResolve = true;

      final isLoggedIn = authState.value != null;
      final onSplash = loc == _splashRoute;
      final isAuthRoute = loc.startsWith('/auth');

      if (!isLoggedIn) {
        // Splash is never a valid resting place — once auth resolves to
        // "not logged in", it must hand off to the phone screen explicitly.
        // Everything else already under /auth (phone/otp/name) can stay put.
        if (onSplash) return '/auth/phone';
        return isAuthRoute ? null : '/auth/phone';
      }

      // isLoading (not !hasValue) — right after sign-in, these providers
      // rebuild from their pre-login state (role/profile for a signed-out
      // user), and Riverpod's default rebuild behavior carries the *old*
      // value forward as .value while isLoading stays true until the fresh
      // data lands. !hasValue misses that window entirely: profile.hasValue
      // reads true with the old (empty) data, so name.isEmpty below would
      // read true for an instant and flash an existing user through
      // /auth/name before the real Firestore snapshot arrives and corrects
      // it. isLoading stays true through that whole window, so this holds
      // off until the data is actually settled.
      if (role.isLoading || profile.isLoading) return stay();

      // A FAILED profile fetch is not the same as "this user has no name".
      // When /users/me errors (API unreachable, tunnel down, token rejected),
      // isLoading is false, hasError is true and .value is null — so the
      // name.isEmpty test below read empty and bounced people who already had
      // a name onto /auth/name on every launch. Only act on a profile that
      // genuinely loaded; on error stay put so the screen's own retry can run.
      if (profile.hasError || !profile.hasValue) return stay();

      final name = profile.value?['name'] as String? ?? '';
      if (name.isEmpty) return loc == '/auth/name' ? null : '/auth/name';

      if (isAuthRoute || onSplash) {
        return isAdminRole ? _adminShellRoot : _userShellRoot;
      }

      // A role promotion/demotion mid-session (e.g. the web-admin panel
      // granting store-admin rights) only ever updates appRoleProvider —
      // nothing else moves the user out of whichever shell they were
      // already sitting in when it happened.
      if (isAdminRole && loc == _userShellRoot) return _adminShellRoot;
      if (!isAdminRole && loc == _adminShellRoot) return _userShellRoot;

      return stay();
    },
    routes: [
      GoRoute(
        path: _splashRoute,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/auth/phone',
        builder: (context, state) => const PhoneEntryScreen(),
      ),
      GoRoute(
        path: '/auth/otp',
        builder: (context, state) => const OtpScreen(),
      ),
      GoRoute(
        path: '/auth/name',
        builder: (context, state) {
          // Set when the OTP screen bounced here with NAME_REQUIRED — carries
          // the still-valid code so signup can be completed in one call.
          final extra = state.extra as Map<String, dynamic>?;
          return NameEntryScreen(
            pendingPhone: extra?['phone'] as String?,
            pendingCode: extra?['code'] as String?,
          );
        },
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const SearchScreen(),
      ),
      // Tapping a search result opens a shuffled scroll of that media type
      // (posts and reels separately), seeded to the tapped item — see
      // search_pager_screen.dart. Both reuse the search grid's shuffled order.
      GoRoute(
        path: '/search/posts/:postId',
        builder: (context, state) =>
            SearchPostsPagerScreen(initialPostId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/search/reels/:postId',
        builder: (context, state) =>
            SearchReelsPagerScreen(initialPostId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/post/:postId',
        builder: (context, state) {
          final positionMs = state.extra as int?;
          debugPrint(
            'router: building /post/${state.pathParameters['postId']} '
            'extra=${state.extra} positionMs=$positionMs',
          );
          return PostDetailScreen(
            postId: state.pathParameters['postId']!,
            initialPosition: positionMs != null
                ? Duration(milliseconds: positionMs)
                : null,
          );
        },
      ),
      GoRoute(
        path: '/store/:storeId',
        builder: (context, state) =>
            StoreProfileScreen(storeId: state.pathParameters['storeId']!),
      ),
      // Share-link paths (share_links.dart: /p image or carousel post, /r
      // reel, /s store). Never a resting location — redirect parks the
      // target and pushes /post or /store over the shell — but go_router has
      // to match the incoming URI to run redirect with it at all, and these
      // are the fallback should one ever slip through.
      GoRoute(
        path: '/p/:id',
        builder: (context, state) =>
            PostDetailScreen(postId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/r/:id',
        builder: (context, state) =>
            PostDetailScreen(postId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/s/:id',
        builder: (context, state) =>
            StoreProfileScreen(storeId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/home/story/:storeId',
        builder: (context, state) => StoryViewerScreen(
          storeId: state.pathParameters['storeId']!,
          args: state.extra as StoryViewerArgs?,
        ),
      ),
      GoRoute(
        path: '/admin/store/:storeId',
        builder: (context, state) =>
            StoreProfileScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/admin/store',
        builder: (context, state) => const MyStoreScreen(),
      ),
      GoRoute(
        path: '/admin/store/:storeId/edit',
        builder: (context, state) =>
            EditStoreScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/admin/settings',
        builder: (context, state) => const AdminSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/notifications',
        builder: (context, state) => const ProfileNotificationsScreen(),
      ),
      GoRoute(
        path: '/settings/edit-profile',
        builder: (context, state) => const EditProfileScreen(),
      ),
      GoRoute(
        path: '/settings/liked',
        builder: (context, state) => const PostIdGrid(kind: PostGridKind.liked),
      ),
      GoRoute(
        path: '/settings/saved',
        builder: (context, state) => const PostIdGrid(kind: PostGridKind.saved),
      ),
      GoRoute(
        path: '/settings/quick-replies/:storeId',
        builder: (context, state) =>
            QuickRepliesScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/settings/notification-requests/:storeId',
        builder: (context, state) => NotificationRequestScreen(
          storeId: state.pathParameters['storeId']!,
        ),
      ),
      GoRoute(
        path: '/settings/orders/:storeId',
        builder: (context, state) =>
            OrdersScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/admin/home/story/:storeId',
        builder: (context, state) => StoryViewerScreen(
          storeId: state.pathParameters['storeId']!,
          args: state.extra as StoryViewerArgs?,
        ),
      ),
      GoRoute(
        path: '/chat/:chatId',
        builder: (context, state) =>
            ChatThreadScreen(chatId: state.pathParameters['chatId']!),
      ),
      GoRoute(
        path: '/admin/chat/:chatId',
        builder: (context, state) =>
            ChatThreadScreen(chatId: state.pathParameters['chatId']!),
      ),
      GoRoute(
        path: _userShellRoot,
        builder: (context, state) => const _SwipeableTabShell(isAdmin: false),
      ),
      GoRoute(
        path: _adminShellRoot,
        builder: (context, state) => const _SwipeableTabShell(isAdmin: true),
      ),
    ],
  );
  // Every navigation the router settles is a chance for a parked share link
  // to find the shell underneath it (splash -> shell, /auth/* -> shell).
  router.routerDelegate.addListener(scheduleDeepLinkDispatch);
  ref.onDispose(
    () => router.routerDelegate.removeListener(scheduleDeepLinkDispatch),
  );
  return router;
});

class _TabIcon {
  const _TabIcon({
    required this.inactive,
    required this.active,
    required this.label,
  });

  final Widget inactive;
  final Widget active;
  final String label;
}

// Like the other four tabs, home now ships both a thin outline variant
// (home_outline.svg) and the solid glyph (home.svg) for its active state.
//
// A function, not a top-level const list — AppColors.textSecondary/.brand
// are brightness-aware getters (see theme.dart), not compile-time
// constants, so this needs to be re-evaluated on every build to pick up a
// theme change instead of freezing whichever colors were live the first
// time this file was loaded.
// Figma "Menu bar 2" (426:2161) draws every nav glyph in a 28pt box.
const double _navIconSize = 28;

List<_TabIcon> _buildTabIcons() => [
  _TabIcon(
    inactive: AppIcon('home_outline', size: _navIconSize, color: AppColors.textSecondary),
    active: AppIcon('home', size: _navIconSize, color: AppColors.brand),
    label: 'Home',
  ),
  _TabIcon(
    inactive: AppIcon('play_square', size: _navIconSize, color: AppColors.textSecondary),
    active: AppIcon('play_square_filled', size: _navIconSize, color: AppColors.brand),
    label: 'Reels',
  ),
  _TabIcon(
    inactive: AppIcon('trophy_star', size: _navIconSize, color: AppColors.textSecondary),
    active: AppIcon('trophy_star_filled', size: _navIconSize, color: AppColors.brand),
    label: 'Leaderboard',
  ),
  _TabIcon(
    inactive: AppIcon('send', size: _navIconSize, color: AppColors.textSecondary),
    active: AppIcon('send_filled', size: _navIconSize, color: AppColors.brand),
    label: 'Chat',
  ),
  _TabIcon(
    inactive: AppIcon('user', size: _navIconSize, color: AppColors.textSecondary),
    active: AppIcon('user_filled', size: _navIconSize, color: AppColors.brand),
    label: 'Profile',
  ),
];

/// The 5-tab bottom nav, rebuilt on a real `PageView` instead of go_router's
/// `StatefulShellRoute.indexedStack` so swiping between tabs is a genuine,
/// finger-tracked, interruptible transition (matching each branch's icon
/// cross-fading between outline/filled as you drag) — not just a snap once
/// a gesture is detected. `StatefulShellRoute` was dropped entirely for
/// this: its branches each pin their own Navigator to a GlobalKey, and any
/// approach that tries to keep an outgoing and incoming branch mounted
/// together mid-transition (which a real drag-through needs) duplicates
/// those keys and crashes. A plain PageView carries no such constraint —
/// each page here is just a normal widget, kept alive (see ShellTabPager in
/// shell_tab.dart) so switching tabs still preserves scroll position like
/// IndexedStack did. Which tab may actually *play* video is published by
/// that pager (settledShellTabProvider) rather than guessed by each tab.
class _SwipeableTabShell extends StatefulWidget {
  const _SwipeableTabShell({required this.isAdmin});

  final bool isAdmin;

  @override
  State<_SwipeableTabShell> createState() => _SwipeableTabShellState();
}

class _SwipeableTabShellState extends State<_SwipeableTabShell> {
  late final PageController _pageController = PageController()
    ..addListener(_dismissKeyboardOnScroll);
  int _settledIndex = 0;

  @override
  void initState() {
    super.initState();
    debugPrint('router: _SwipeableTabShellState CREATED hash=$hashCode');
  }

  void _goToPage(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  // Fires continuously as the page position moves — including mid-drag, not
  // just once a swipe settles — so a reel's reply field (or any other tab's
  // open keyboard) closes the instant the user starts swiping to another
  // tab, instead of staying open and covering whatever tab they land on.
  void _dismissKeyboardOnScroll() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    debugPrint('router: _SwipeableTabShellState DISPOSED hash=$hashCode');
    _pageController.removeListener(_dismissKeyboardOnScroll);
    _pageController.dispose();
    super.dispose();
  }

  List<Widget> _buildPages() {
    final reels = ReelsScreen(onExitToHome: () => _goToPage(0));
    if (widget.isAdmin) {
      return [
        const AdminHomeScreen(),
        reels,
        const LeaderboardScreen(),
        const ChatListScreen(),
        const AdminOwnStoreScreen(),
      ];
    }
    return [
      const FeedScreen(),
      reels,
      const LeaderboardScreen(),
      const ChatListScreen(),
      const SettingsScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Reels still swipes to its neighbors like every other tab — the scrub
    // bar only claims its own thin strip at the bottom of the screen, so a
    // full-width swipe starting anywhere else doesn't compete with it. The
    // back arrow (wired to _goToPage(0) above) and the system back gesture
    // below are just an extra shortcut straight to Home.
    final onReels = _settledIndex == kReelsTabIndex;
    return Scaffold(
      body: PopScope(
        canPop: !onReels,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && onReels) _goToPage(0);
        },
        child: ShellTabPager(
          controller: _pageController,
          onPageChanged: (index) => setState(() => _settledIndex = index),
          pages: _buildPages(),
        ),
      ),
      bottomNavigationBar: onReels
          ? null
          : TabNavBar(
              controller: _pageController,
              settledIndex: _settledIndex,
              onTap: _goToPage,
            ),
    );
  }
}

/// Custom bottom nav bar (replacing Flutter's stock NavigationBar) so each
/// icon can cross-fade between its outline and filled variant continuously
/// as `controller`'s page value moves — driven by the live drag position,
/// the same "alpha fading tied to swipe percentage" Instagram itself uses,
/// not just a binary selected/unselected swap on settle. The Chat item
/// carries the unread badge (totalUnreadChatCountProvider, role-aware).
/// Public only so test/chat/chat_tab_badge_test.dart can mount it on its
/// own; the shell above is its one caller.
class TabNavBar extends ConsumerWidget {
  const TabNavBar({
    super.key,
    required this.controller,
    required this.settledIndex,
    required this.onTap,
  });

  final PageController controller;
  final int settledIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabIcons = _buildTabIcons();
    final unreadChats = ref.watch(totalUnreadChatCountProvider);
    return SafeArea(
      top: false,
      // Figma "Menu bar 2" (426:2161): 80pt tall, card background, a 1pt top
      // divider, 20pt side padding / 16pt vertical, 12pt between items.
      child: Container(
        height: 80,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.backgroundCard,
          border: Border(top: BorderSide(color: AppColors.borderDivider)),
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final page =
                controller.hasClients && controller.position.haveDimensions
                ? controller.page ?? settledIndex.toDouble()
                : settledIndex.toDouble();
            return Row(
              children: [
                for (var i = 0; i < tabIcons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: _NavIconButton(
                      icon: tabIcons[i],
                      activation: (1 - (page - i).abs()).clamp(0.0, 1.0),
                      onTap: () => onTap(i),
                      badgeCount: i == kChatTabIndex ? unreadChats : 0,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavIconButton extends StatelessWidget {
  const _NavIconButton({
    required this.icon,
    required this.activation,
    required this.onTap,
    this.badgeCount = 0,
  });

  final _TabIcon icon;
  final double activation;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      // Figma 195:8153: each item fills its share of the row (flex-1) with 6pt
      // vertical padding and a 36pt radius — the pill spans the full item
      // width rather than hugging the icon, so it can't be a Center + fixed
      // horizontal padding. The active tint is brand at 10%, which the
      // activation factor cross-fades as the pager is dragged.
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.1 * activation),
          borderRadius: BorderRadius.circular(36),
        ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Opacity(opacity: 1 - activation, child: icon.inactive),
              Opacity(opacity: activation, child: icon.active),
              if (badgeCount > 0)
                Positioned(
                  top: -2,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    constraints: const BoxConstraints(minWidth: 16),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppColors.backgroundCard,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      badgeCount > 99 ? '99+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
