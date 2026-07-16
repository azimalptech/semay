import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';

// TODO(phase-5-blocked): Figma "trophy-star" nav tab. Confirmed: rank by
// summed orders.itemQuantity, scoped per-store (no new fields — uses
// orders.storeId/userId already written by acceptOrder). BLOCKED on a real
// implementation: docs/03_CLOUD_FUNCTIONS_API.md's security rules restrict
// `orders` reads to Super Admin + that store's admins only — a regular User
// can't query orders directly under the current rules. Needs either (a) a
// callable Cloud Function that computes the ranking server-side and returns
// only the aggregate (keeps raw orders private), or (b) a deliberate rules
// change to expose per-store order data to any authenticated user — pick
// one before building this for real.
class LeaderboardScreen extends ConsumerWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Text(ref.watch(l10nProvider).leaderboardSoon, style: AppTypography.bodyMedium),
      ),
    );
  }
}
