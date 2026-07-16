import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/quick_replies_service.dart';

class QuickRepliesScreen extends ConsumerWidget {
  const QuickRepliesScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.quickReplies),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: AppColors.textPrimary),
            onPressed: () => _showEditSheet(context, ref, storeId: storeId),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(s.quickRepliesHelp, style: AppTypography.bodySmall),
          ),
          Expanded(
            child: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
              stream: ref.watch(quickRepliesServiceProvider).watch(storeId),
              builder: (context, snapshot) {
                final docs = snapshot.data ?? [];
                if (docs.isEmpty) {
                  return Center(
                    child: Text(s.noQuickRepliesYet, style: AppTypography.bodyMedium),
                  );
                }
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, color: AppColors.borderDivider),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final text = doc.data()['text'] as String? ?? '';
                    return ListTile(
                      leading: const Icon(Icons.drag_indicator, color: AppColors.textMuted),
                      title: Text(text, style: AppTypography.bodyMedium),
                      onTap: () => _showEditSheet(
                        context,
                        ref,
                        storeId: storeId,
                        replyId: doc.id,
                        initialText: text,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showEditSheet(
  BuildContext context,
  WidgetRef ref, {
  required String storeId,
  String? replyId,
  String? initialText,
}) async {
  final s = ref.read(l10nProvider);
  final controller = TextEditingController(text: initialText ?? '');
  final isEdit = replyId != null;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.backgroundCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => Padding(
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
              Text(isEdit ? s.editQuickReply : s.addQuickReply, style: AppTypography.titleLarge),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, color: AppColors.textPrimary),
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
          TextField(
            controller: controller,
            maxLines: 3,
            style: AppTypography.bodyMedium,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          if (isEdit)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await ref.read(quickRepliesServiceProvider).delete(storeId, replyId);
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                    },
                    child: Text(s.delete),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
                    onPressed: () async {
                      final text = controller.text.trim();
                      if (text.isEmpty) return;
                      await ref.read(quickRepliesServiceProvider).update(storeId, replyId, text);
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                    },
                    child: Text(s.save),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
                onPressed: () async {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  await ref.read(quickRepliesServiceProvider).add(storeId, text, DateTime.now().millisecondsSinceEpoch);
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                },
                child: Text(s.add),
              ),
            ),
        ],
      ),
    ),
  );
}
