import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import 'leaderboard_providers.dart';

/// Trophy nav tab — per-shop ranking of the users who ordered the most items
/// from that store since that store's own Super-Admin-configured campaign
/// start date (see docs/02_DATA_MODEL.md's stores/{storeId}.campaignStartAt
/// and stores/{storeId}/leaderboard entries — each store runs an independent
/// campaign, not a shared global one).
class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  String? _selectedStoreId;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final storesAsync = ref.watch(leaderboardStoresProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.topUsers)),
      body: storesAsync.when(
        // A pull that fails must not take the tabs, the campaign banner and
        // the ranking with it: `.when` routes an AsyncError to `error` even
        // when the previous value is still in `.value` (skipError defaults to
        // false), so before this a failed refresh replaced the whole screen
        // with one line of error text. _pullLeaderboard reports the failure
        // instead. A cold load that fails has no previous value and still
        // shows the error branch.
        skipError: true,
        data: (stores) {
          if (stores.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => _pullLeaderboard(context, ref, null),
              child: _PullableMessage(message: s.noLeaderboardYet),
            );
          }
          _selectedStoreId ??= stores.first.storeId;
          final selected = stores.any((t) => t.storeId == _selectedStoreId)
              ? _selectedStoreId!
              : stores.first.storeId;
          final selectedStore = stores.firstWhere((t) => t.storeId == selected);
          final giftImageUrl = selectedStore.campaignImageUrl;

          return Column(
            children: [
              _ShopTabs(
                stores: stores,
                selectedStoreId: selected,
                onSelect: (id) => setState(() => _selectedStoreId = id),
              ),
              if (giftImageUrl != null && giftImageUrl.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      // 3x2 banner, per the Super Admin upload spec.
                      aspectRatio: 3 / 2,
                      child: CachedNetworkImage(
                        imageUrl: giftImageUrl,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              Expanded(child: _RankedList(storeId: selected)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => RefreshIndicator(
          onRefresh: () => _pullLeaderboard(context, ref, null),
          child: _PullableMessage(message: '${s.failedToLoad}: $error'),
        ),
      ),
    );
  }
}

class _ShopTabs extends StatelessWidget {
  const _ShopTabs({
    required this.stores,
    required this.selectedStoreId,
    required this.onSelect,
  });

  final List<StoreTab> stores;
  final String selectedStoreId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: stores.length,
        separatorBuilder: (context, index) => const SizedBox(width: 20),
        itemBuilder: (context, index) {
          final store = stores[index];
          final selected = store.storeId == selectedStoreId;
          return GestureDetector(
            onTap: () => onSelect(store.storeId),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  store.name,
                  style: AppTypography.bodyMediumSemibold.copyWith(
                    color: selected ? AppColors.brand : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 2,
                  width: 24,
                  color: selected ? AppColors.brand : Colors.transparent,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RankedList extends ConsumerWidget {
  const _RankedList({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final entriesAsync = ref.watch(leaderboardEntriesProvider(storeId));

    // Pulling the ranking refreshes the shop tabs above it as well — they are
    // the same screen to the user, and both are one-shot REST reads.
    return RefreshIndicator(
      onRefresh: () => _pullLeaderboard(context, ref, storeId),
      child: entriesAsync.when(
        // Same reason as the tabs above: a failed pull keeps the ranking the
        // user is looking at, and says so in a snackbar.
        skipError: true,
        data: (docs) {
          if (docs.isEmpty) {
            return _PullableMessage(message: s.noLeaderboardYet);
          }
          return ListView.builder(
            // A ranking shorter than the screen must still be pullable.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data();
              return _RankRow(
                rank: index + 1,
                name: data['userName'] as String? ?? '',
                quantity: data['quantity'] as int? ?? 0,
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            _PullableMessage(message: '${s.failedToLoad}: $error'),
      ),
    );
  }
}

/// Pull-to-refresh with a failure that is heard but not destructive: the
/// screen keeps whatever it was showing (see `skipError`), and a snackbar says
/// the refresh did not work.
Future<void> _pullLeaderboard(
  BuildContext context,
  WidgetRef ref,
  String? storeId,
) async {
  final ok = await refreshLeaderboard(ref, storeId);
  if (ok || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(ref.read(l10nProvider).failedToLoad)));
}

/// A centred message that is still a scrollable, so the empty and error states
/// can be pulled down to retry exactly like the ranking can.
class _PullableMessage extends StatelessWidget {
  const _PullableMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyMedium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.name,
    required this.quantity,
  });

  final int rank;
  final String name;
  final int quantity;

  Color get _badgeColor => switch (rank) {
    1 => const Color(0xFFF5A623),
    2 => const Color(0xFF9B9B9B),
    3 => const Color(0xFFB5651D),
    _ => AppColors.backgroundCard,
  };

  Color get _badgeTextColor => rank <= 3 ? Colors.white : AppColors.textPrimary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text('$rank', style: AppTypography.bodyMedium),
          ),
          const SizedBox(width: 12),
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.buttonMuted,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: AppTypography.bodyMediumSemibold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: AppTypography.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: 32,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _badgeColor,
              borderRadius: BorderRadius.circular(12),
              border: rank > 3
                  ? Border.all(color: AppColors.borderDivider)
                  : null,
            ),
            child: Text(
              '$quantity',
              style: AppTypography.bodySmall.copyWith(
                color: _badgeTextColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
