import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_icon.dart';
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

  return GoRouter(
    // Set once here, not created fresh per GoRouter instance — the same
    // "global key wired up before runApp, used by code with no
    // BuildContext of its own" pattern rootNavigatorKey's own doc comment
    // describes. This is what lets showForegroundMessageBanner reach the
    // root Overlay and call GoRouter.of(context) from outside the widget
    // tree entirely.
    navigatorKey: rootNavigatorKey,
    initialLocation: _splashRoute,
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final authState = ref.read(authStateChangesProvider);
      final role = ref.read(appRoleProvider);
      final profile = ref.read(userProfileProvider);

      final loc = state.matchedLocation;
      debugPrint(
        'router: redirect() loc=$loc matchedLocation=${state.matchedLocation} '
        'uri=${state.uri} fullPath=${state.fullPath}',
      );

      // Firebase Auth hasn't finished checking for a persisted session yet
      // (authStateChangesProvider's first, async emission) — stay on the
      // splash screen instead of flashing the login screen for an instant
      // before bouncing an already-signed-in user straight back out of it.
      // Only applies before the very first successful resolve — see
      // pastInitialAuthResolve's comment above.
      if (!authState.hasValue) {
        if (pastInitialAuthResolve) return null;
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
      if (role.isLoading || profile.isLoading) return null;

      // A FAILED profile fetch is not the same as "this user has no name".
      // When /users/me errors (API unreachable, tunnel down, token rejected),
      // isLoading is false, hasError is true and .value is null — so the
      // name.isEmpty test below read empty and bounced people who already had
      // a name onto /auth/name on every launch. Only act on a profile that
      // genuinely loaded; on error stay put so the screen's own retry can run.
      if (profile.hasError || !profile.hasValue) return null;

      final name = profile.value?['name'] as String? ?? '';
      if (name.isEmpty) return loc == '/auth/name' ? null : '/auth/name';

      final isAdminRole = role.value != AppRole.user;

      if (isAuthRoute || onSplash) {
        return isAdminRole ? _adminShellRoot : _userShellRoot;
      }

      // A role promotion/demotion mid-session (e.g. the web-admin panel
      // granting store-admin rights) only ever updates appRoleProvider —
      // nothing else moves the user out of whichever shell they were
      // already sitting in when it happened.
      if (isAdminRole && loc == _userShellRoot) return _adminShellRoot;
      if (!isAdminRole && loc == _adminShellRoot) return _userShellRoot;

      return null;
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
});

// Figma-defined order for both roles' MenuBar2: home, play-square (Reels),
// trophy-star (Leaderboard), send (Chat), user (Profile).
const _reelsPageIndex = 1;
const _chatPageIndex = 3;

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
/// each page here is just a normal widget, kept alive via
/// AutomaticKeepAliveClientMixin so switching tabs still preserves scroll
/// position/video playback exactly like IndexedStack did.
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
    final onReels = _settledIndex == _reelsPageIndex;
    return Scaffold(
      body: PopScope(
        canPop: !onReels,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && onReels) _goToPage(0);
        },
        child: PageView(
          controller: _pageController,
          onPageChanged: (index) => setState(() => _settledIndex = index),
          children: [
            for (final page in _buildPages()) _KeepAlivePage(child: page),
          ],
        ),
      ),
      bottomNavigationBar: onReels
          ? null
          : _TabNavBar(
              controller: _pageController,
              settledIndex: _settledIndex,
              onTap: _goToPage,
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

/// Custom bottom nav bar (replacing Flutter's stock NavigationBar) so each
/// icon can cross-fade between its outline and filled variant continuously
/// as `controller`'s page value moves — driven by the live drag position,
/// the same "alpha fading tied to swipe percentage" Instagram itself uses,
/// not just a binary selected/unselected swap on settle.
class _TabNavBar extends ConsumerWidget {
  const _TabNavBar({
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
                      badgeCount: i == _chatPageIndex ? unreadChats : 0,
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
