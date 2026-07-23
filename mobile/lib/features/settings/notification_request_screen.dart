import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import 'notification_request_providers.dart';

/// Store Admin's "request Super Admin send a notification to everyone" flow
/// — compose at the top (via the + action), history with live status below.
/// See requestBroadcastNotification.ts / decideNotificationRequest.ts.
class NotificationRequestScreen extends ConsumerWidget {
  const NotificationRequestScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final requestsAsync = ref.watch(myNotificationRequestsProvider(storeId));
    final docs = requestsAsync.value ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(s.requestNotification),
        actions: [
          IconButton(
            icon: AppIcon('plus', color: AppColors.textPrimary),
            onPressed: () => _showComposeSheet(context, ref, storeId: storeId),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              s.requestNotificationDesc,
              style: AppTypography.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              s.yourRequests,
              style: AppTypography.bodyMediumSemibold,
            ),
          ),
          Expanded(
            child: docs.isEmpty
                ? Center(
                    child: Text(
                      s.noRequestsYet,
                      style: AppTypography.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final data = docs[index].data();
                      return _RequestTile(
                        message: data['message'] as String? ?? '',
                        status: data['status'] as String? ?? 'pending',
                        s: s,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showComposeSheet(
  BuildContext context,
  WidgetRef ref, {
  required String storeId,
}) async {
  final s = ref.read(l10nProvider);
  final controller = TextEditingController();
  var submitting = false;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.backgroundCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setState) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(s.requestNotification, style: AppTypography.titleLarge),
                const Spacer(),
                IconButton(
                  icon: AppIcon('close', color: AppColors.textPrimary),
                  onPressed: submitting
                      ? null
                      : () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
            TextField(
              controller: controller,
              maxLines: 5,
              minLines: 3,
              style: AppTypography.bodyMedium,
              decoration: InputDecoration(
                hintText: s.notificationMessageHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
                onPressed: submitting
                    ? null
                    : () async {
                        final message = controller.text.trim();
                        if (message.isEmpty) return;
                        setState(() => submitting = true);
                        try {
                          await ref
                              .read(notificationRequestServiceProvider)
                              .requestBroadcast(
                                storeId: storeId,
                                message: message,
                              );
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(s.requestSent)),
                            );
                          }
                        } catch (e) {
                          setState(() => submitting = false);
                          if (sheetContext.mounted) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              SnackBar(content: Text(s.requestFailed)),
                            );
                          }
                        }
                      },
                child: submitting
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(s.sendRequest),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  controller.dispose();
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.message,
    required this.status,
    required this.s,
  });

  final String message;
  final String status;
  final S s;

  @override
  Widget build(BuildContext context) {
    final Color badgeColor;
    final String label;
    switch (status) {
      case 'approved':
        badgeColor = AppColors.callGreen;
        label = s.statusApproved;
      case 'rejected':
        badgeColor = AppColors.error;
        label = s.statusRejected;
      default:
        badgeColor = const Color(0xFFF4832E);
        label = s.statusPending;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderDivider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(message, style: AppTypography.bodyMedium)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: AppTypography.caption.copyWith(color: badgeColor),
            ),
          ),
        ],
      ),
    );
  }
}
