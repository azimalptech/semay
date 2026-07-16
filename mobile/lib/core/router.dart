import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_icon.dart';
import 'theme.dart';
import '../features/auth/name_entry_screen.dart';
import '../features/auth/otp_screen.dart';
import '../features/auth/phone_entry_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_thread_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/leaderboard/leaderboard_screen.dart';
import '../features/profile/liked_screen.dart';
import '../features/profile/profile_notifications_screen.dart';
import '../features/reels/reels_screen.dart';
import '../features/search/search_screen.dart';
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

// Bare tab roots of each StatefulShellRoute below — used only to detect "is
// the user sitting in the wrong role's shell", never matched against shared
// detail routes like /post/:id or /chat/:id that both roles use.
const _userShellRoots = {'/home', '/reels', '/leaderboard', '/chat', '/profile'};
const _adminShellRoots = {
  '/admin/home',
  '/admin/reels',
  '/admin/leaderboard',
  '/admin/chat',
  '/admin/profile',
};

// Role-based redirect: unauthenticated -> /auth/phone; authenticated with an
// incomplete profile (empty users/{uid}.name, set by verifyOtp) -> /auth/name;
// otherwise -> /home (user) or /admin/home (admin/superadmin).
final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateChangesProvider);
  final role = ref.watch(appRoleProvider);
  final profile = ref.watch(userProfileProvider);

  return GoRouter(
    initialLocation: '/auth/phone',
    redirect: (context, state) {
      final isLoggedIn = authState.value != null;
      final loc = state.matchedLocation;
      final isAuthRoute = loc.startsWith('/auth');

      if (!isLoggedIn) return isAuthRoute ? null : '/auth/phone';

      if (!role.hasValue || !profile.hasValue) return null;

      final name = profile.value?['name'] as String? ?? '';
      if (name.isEmpty) return loc == '/auth/name' ? null : '/auth/name';

      final isAdminRole = role.value != AppRole.user;

      if (isAuthRoute) {
        return isAdminRole ? '/admin/home' : '/home';
      }

      // A role promotion/demotion mid-session (e.g. the web-admin panel
      // granting store-admin rights) only ever updates appRoleProvider —
      // nothing else moves the user out of whichever shell they were
      // already sitting in when it happened. Only steer away from a shell
      // tab's own root, never a shared detail route both roles use
      // (/post/:id, /store/:id, /chat/:id, /settings/*, ...).
      if (isAdminRole && _userShellRoots.contains(loc)) return '/admin/home';
      if (!isAdminRole && _adminShellRoots.contains(loc)) return '/home';

      return null;
    },
    routes: [
      GoRoute(path: '/auth/phone', builder: (context, state) => const PhoneEntryScreen()),
      GoRoute(
        path: '/auth/otp',
        builder: (context, state) => OtpScreen(phone: state.extra as String? ?? ''),
      ),
      GoRoute(path: '/auth/name', builder: (context, state) => const NameEntryScreen()),
      GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
      GoRoute(
        path: '/post/:postId',
        builder: (context, state) => PostDetailScreen(postId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/store/:storeId',
        builder: (context, state) => StoreProfileScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/home/story/:storeId',
        builder: (context, state) => StoryViewerScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/admin/store/:storeId',
        builder: (context, state) => StoreProfileScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(path: '/admin/store', builder: (context, state) => const MyStoreScreen()),
      GoRoute(
        path: '/admin/store/:storeId/edit',
        builder: (context, state) => EditStoreScreen(storeId: state.pathParameters['storeId']!),
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
        path: '/settings/liked',
        builder: (context, state) => const PostIdGrid(kind: PostGridKind.liked),
      ),
      GoRoute(
        path: '/settings/saved',
        builder: (context, state) => const PostIdGrid(kind: PostGridKind.saved),
      ),
      GoRoute(
        path: '/settings/quick-replies/:storeId',
        builder: (context, state) => QuickRepliesScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/settings/orders/:storeId',
        builder: (context, state) => OrdersScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/admin/home/story/:storeId',
        builder: (context, state) => StoryViewerScreen(storeId: state.pathParameters['storeId']!),
      ),
      GoRoute(
        path: '/chat/:chatId',
        builder: (context, state) => ChatThreadScreen(chatId: state.pathParameters['chatId']!),
      ),
      GoRoute(
        path: '/admin/chat/:chatId',
        builder: (context, state) => ChatThreadScreen(chatId: state.pathParameters['chatId']!),
      ),
      // Figma frame 195:4299, node 195:8152 "MenuBar2" — 5 icon-only tabs:
      // home, play-square (Reels), trophy-star (Leaderboard), send (Chat), user (Profile).
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => _RoleScaffold(
          navigationShell: navigationShell,
          destinations: [
            _homeNavDestination(),
            _navDestination('play_square', 'Reels'),
            _navDestination('trophy_star', 'Leaderboard'),
            _navDestination('send', 'Chat'),
            _navDestination('user', 'Profile'),
          ],
        ),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/home', builder: (context, state) => const FeedScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/reels', builder: (context, state) => const ReelsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/leaderboard', builder: (context, state) => const LeaderboardScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/chat', builder: (context, state) => const ChatListScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/profile', builder: (context, state) => const SettingsScreen()),
          ]),
        ],
      ),
      // Figma frame 223:4759 (Store Admin Homepage) uses the identical
      // MenuBar2 component/icons as the User section (195:4299) — same 5
      // tabs, not a distinct admin nav. Profile tab shows the admin's own
      // Store Detail page (AdminOwnStoreScreen); Settings sits one level
      // behind its gear icon (AdminSettingsScreen).
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => _RoleScaffold(
          navigationShell: navigationShell,
          destinations: [
            _homeNavDestination(),
            _navDestination('play_square', 'Reels'),
            _navDestination('trophy_star', 'Leaderboard'),
            _navDestination('send', 'Chat'),
            _navDestination('user', 'Profile'),
          ],
        ),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/home', builder: (context, state) => const AdminHomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/reels', builder: (context, state) => const ReelsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/leaderboard', builder: (context, state) => const LeaderboardScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/chat', builder: (context, state) => const ChatListScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/profile', builder: (context, state) => const AdminOwnStoreScreen()),
          ]),
        ],
      ),
    ],
  );
});

class _RoleScaffold extends StatelessWidget {
  const _RoleScaffold({required this.navigationShell, required this.destinations});

  final StatefulNavigationShell navigationShell;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        indicatorColor: AppColors.brand.withValues(alpha: 0.1),
        backgroundColor: AppColors.backgroundCard,
        indicatorShape: const StadiumBorder(),
        destinations: destinations,
      ),
    );
  }
}

// The Figma SVG assets, tinted per state — active reads as brand color plus
// the stadium indicator pill behind it. (These assets ship a single variant
// each, so there is no separate outline/filled glyph to swap.)
NavigationDestination _navDestination(String asset, String label) {
  return NavigationDestination(
    icon: AppIcon(asset, color: AppColors.textSecondary),
    selectedIcon: AppIcon(asset, color: AppColors.brand),
    label: label,
  );
}

// home.svg is the one asset of the five drawn as a solid glyph (the other
// four — play_square/trophy_star/send/user — are already thin outline
// paths), so tinting it never reads as "inactive": it looks filled/active
// at all times. Material's home_outlined stands in for the inactive state
// only; the active state still uses the real Figma asset, matching the rest.
NavigationDestination _homeNavDestination() {
  return NavigationDestination(
    icon: const Icon(Icons.home_outlined, color: AppColors.textSecondary),
    selectedIcon: const AppIcon('home', color: AppColors.brand),
    label: 'Home',
  );
}
