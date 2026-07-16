import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../settings/settings_screen.dart';
import '../store_profile/store_profile_screen.dart';

/// Resolves the admin's storeId reactively before handing off to the shared
/// SettingsScreen (Figma "Settings" frame — same UI as User's Profile tab,
/// plus the two store-scoped rows). Reached via the gear icon on
/// AdminOwnStoreScreen, not directly from the bottom nav (see docs/04 —
/// Profile tab shows the Store Detail page, matching how the Figma flow
/// nests Settings one level behind the store's own profile).
class AdminSettingsScreen extends ConsumerWidget {
  const AdminSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    return SettingsScreen(storeId: storeIds.isNotEmpty ? storeIds.first : null);
  }
}

/// Profile bottom-nav tab for admins (Figma "Store Detail" frame): their own
/// store's profile page, complete with Edit Profile/Share, posts+reels tabs,
/// and the settings gear — not a shortcut straight to Settings.
class AdminOwnStoreScreen extends ConsumerWidget {
  const AdminOwnStoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    if (storeIds.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.push('/admin/settings'),
            ),
          ],
        ),
        body: const SizedBox.shrink(),
      );
    }
    return StoreProfileScreen(storeId: storeIds.first);
  }
}
