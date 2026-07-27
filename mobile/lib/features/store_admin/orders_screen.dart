import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';

/// Store Admin's own-store order history — figma "Orders" frame, reached from
/// Settings. REST fetch + pull-to-refresh (no realtime channel for orders;
/// they're an infrequent, reporting-only surface — see docs/07_MIGRATION.md).
final storeOrdersProvider = FutureProvider.family<List<Map<String, dynamic>>, String>((
  ref,
  storeId,
) async {
  final json = await ref.watch(apiClientProvider).get(
    '/orders',
    query: {'storeId': storeId},
  );
  return (json['orders'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>();
}, isAutoDispose: true);

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final ordersAsync = ref.watch(storeOrdersProvider(storeId));

    return Scaffold(
      appBar: AppBar(title: Text(s.orders)),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(storeOrdersProvider(storeId)),
        child: ordersAsync.when(
          data: (orders) {
            if (orders.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Text(s.noOrdersYet, style: AppTypography.bodyMedium),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: AppColors.borderDivider),
              itemBuilder: (context, index) {
                final order = orders[index];
                final phone = order['userPhone'] as String? ?? '';
                final quantity = order['itemQuantity'] as int? ?? 0;
                final createdAt = parseTimestamp(order['createdAt']);
                return ListTile(
                  title: Text(phone, style: AppTypography.bodyMediumSemibold),
                  subtitle: Text(
                    s.orderedItems(quantity),
                    style: AppTypography.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  trailing: createdAt != null
                      ? Text(
                          _formatDate(createdAt),
                          style: AppTypography.caption.copyWith(
                            color: AppColors.textMuted,
                          ),
                        )
                      : null,
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              const SizedBox(height: 120),
              Center(child: Text(s.failedToLoad)),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.month}/${date.day}, $hour:$minute';
}
