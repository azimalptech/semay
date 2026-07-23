import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/firestore_service.dart';

/// Store Admin's own-store order history — figma "Orders" frame, reached
/// from Settings. Distinct from Super Admin's read-only aggregate dashboard:
/// this lists individual orders for the admin's own store(s) only, which
/// docs/03_CLOUD_FUNCTIONS_API.md's security rules already permit
/// ("read restricted to Super Admin and the store's admins").
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final ordersStream = ref
        .watch(firestoreProvider)
        .collection('orders')
        .where('storeId', isEqualTo: storeId)
        .orderBy('createdAt', descending: true)
        .snapshots();

    return Scaffold(
      appBar: AppBar(title: Text(s.orders)),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: ordersStream,
        builder: (context, snapshot) {
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Text(s.noOrdersYet, style: AppTypography.bodyMedium),
            );
          }
          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (context, index) =>
                Divider(height: 1, color: AppColors.borderDivider),
            itemBuilder: (context, index) {
              final order = docs[index].data();
              final phone = order['userPhone'] as String? ?? '';
              final quantity = order['itemQuantity'] as int? ?? 0;
              final createdAt = (order['createdAt'] as Timestamp?)?.toDate();
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
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.month}/${date.day}, $hour:$minute';
}
