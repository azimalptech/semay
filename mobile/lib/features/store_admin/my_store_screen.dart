import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../services/auth_service.dart';
import '../store_profile/store_profile_screen.dart';

/// Own-store management, reached via the /admin/store deep link — the
/// bottom-nav Profile tab goes through AdminOwnStoreScreen instead, but this
/// route is kept for direct linking. StoreProfileScreen already supplies its
/// own "+" FAB (AddContentSheet), so this is a thin wrapper, not a second one.
class MyStoreScreen extends ConsumerWidget {
  const MyStoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeIds = ref.watch(storeIdsProvider).value ?? [];

    if (storeIds.isEmpty) {
      return Scaffold(
        body: Center(child: Text(ref.watch(l10nProvider).noStoreAssigned)),
      );
    }

    return StoreProfileScreen(storeId: storeIds.first);
  }
}
