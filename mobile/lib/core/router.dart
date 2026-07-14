import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/name_entry_screen.dart';
import '../features/auth/otp_screen.dart';
import '../features/auth/phone_entry_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_thread_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/post_composer/post_composer_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/shared/post_detail_screen.dart';
import '../features/store_admin/admin_home_screen.dart';
import '../features/store_admin/admin_settings_screen.dart';
import '../features/store_admin/my_store_screen.dart';
import '../features/store_profile/store_profile_screen.dart';
import '../features/story_viewer/story_viewer_screen.dart';
import '../services/auth_service.dart';

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

      if (isAuthRoute) {
        return role.value == AppRole.user ? '/home' : '/admin/home';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/auth/phone', builder: (context, state) => const PhoneEntryScreen()),
      GoRoute(
        path: '/auth/otp',
        builder: (context, state) => OtpScreen(phone: state.extra as String? ?? ''),
      ),
      GoRoute(path: '/auth/name', builder: (context, state) => const NameEntryScreen()),
      GoRoute(path: '/compose', builder: (context, state) => const PostComposerScreen()),
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
      GoRoute(
        path: '/admin/home/story/:storeId',
        builder: (context, state) => StoryViewerScreen(storeId: state.pathParameters['storeId']!),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => _RoleScaffold(
          navigationShell: navigationShell,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chat',
            ),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/home', builder: (context, state) => const FeedScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/chat',
              builder: (context, state) => const ChatListScreen(),
              routes: [
                GoRoute(
                  path: ':chatId',
                  builder: (context, state) => ChatThreadScreen(chatId: state.pathParameters['chatId']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
          ]),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => _RoleScaffold(
          navigationShell: navigationShell,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(
              icon: Icon(Icons.storefront_outlined),
              selectedIcon: Icon(Icons.storefront),
              label: 'My Store',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chat',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/home', builder: (context, state) => const AdminHomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/store', builder: (context, state) => const MyStoreScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/admin/chat',
              builder: (context, state) => const ChatListScreen(),
              routes: [
                GoRoute(
                  path: ':chatId',
                  builder: (context, state) => ChatThreadScreen(chatId: state.pathParameters['chatId']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/settings', builder: (context, state) => const AdminSettingsScreen()),
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
        destinations: destinations,
      ),
    );
  }
}
