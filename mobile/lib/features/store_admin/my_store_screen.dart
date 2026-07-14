import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../store_profile/store_profile_screen.dart';

/// Own-store management: reuses StoreProfileScreen's header/Posts/Reels tabs
/// (per-post delete affordance for the owner already lives in PostDetailScreen,
/// gated on the viewer's storeIds claim) plus a compose FAB.
class MyStoreScreen extends ConsumerWidget {
  const MyStoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeIds = ref.watch(storeIdsProvider).value ?? [];

    if (storeIds.isEmpty) {
      return const Scaffold(body: Center(child: Text('No store assigned to this account yet')));
    }

    return Scaffold(
      body: StoreProfileScreen(storeId: storeIds.first),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/compose'),
        child: const Icon(Icons.add),
      ),
    );
  }
}
