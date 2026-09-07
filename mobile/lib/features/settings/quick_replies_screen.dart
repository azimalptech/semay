import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/app_icon.dart';
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
            icon: AppIcon('plus', color: AppColors.textPrimary),
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
            child: ref
                .watch(quickRepliesProvider(storeId))
                .when(
                  data: (docs) {
                    if (docs.isEmpty) {
                      return Center(
                        child: Text(
                          s.noQuickRepliesYet,
                          style: AppTypography.bodyMedium,
                        ),
                      );
                    }
                    return ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (context, index) =>
                          Divider(height: 1, color: AppColors.borderDivider),
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        final text = doc.data()['text'] as String? ?? '';
                        return ListTile(
                          leading: Icon(
                            Icons.drag_indicator,
                            color: AppColors.textMuted,
                          ),
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
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text(s.failedToLoad)),
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
  final service = ref.read(quickRepliesServiceProvider);
  var submitting = false;
  String? errorCode;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.backgroundCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setState) {
        // One path for add/save/delete: the sheet closes only once the server
        // has said yes; a failure keeps it open with the server's error code
        // under the field. The handlers used to `await` the call bare inside
        // `onPressed`, so a 400 surfaced as nothing at all — the sheet just
        // would not close. Inline rather than a SnackBar because a SnackBar
        // is drawn in the Scaffold *under* this sheet, i.e. hidden behind the
        // very sheet whose error it reports.
        Future<void> run(Future<void> Function() mutation) async {
          setState(() {
            submitting = true;
            errorCode = null;
          });
          try {
            await mutation();
          } catch (e) {
            if (sheetContext.mounted) {
              setState(() {
                submitting = false;
                errorCode = e is ApiException ? e.error : '$e';
              });
            }
            return;
          }
          ref.invalidate(quickRepliesProvider(storeId));
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
        }

        return Padding(
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
                  Text(
                    isEdit ? s.editQuickReply : s.addQuickReply,
                    style: AppTypography.titleLarge,
                  ),
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
                maxLines: 3,
                style: AppTypography.bodyMedium,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  errorText: errorCode == null
                      ? null
                      : '${s.requestFailed} ($errorCode)',
                ),
              ),
              const SizedBox(height: 16),
              if (isEdit)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: submitting
                            ? null
                            : () => run(() => service.delete(storeId, replyId)),
                        child: Text(s.delete),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.brand,
                        ),
                        onPressed: submitting
                            ? null
                            : () {
                                final text = controller.text.trim();
                                if (text.isEmpty) return;
                                run(
                                  () => service.update(storeId, replyId, text),
                                );
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
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brand,
                    ),
                    onPressed: submitting
                        ? null
                        : () {
                            final text = controller.text.trim();
                            if (text.isEmpty) return;
                            // Re-read the list rather than trusting the one
                            // on screen: the provider has no value while it
                            // is still loading or after a failed load, and
                            // hands back the *previous* list while a
                            // post-invalidate refetch is in flight — either
                            // way max + 1 of that would land on a slot that
                            // is already taken (0, or the row just added)
                            // and the new reply would tie instead of listing
                            // last. A fetch failure surfaces like any other
                            // error here. Stays a small int (see
                            // nextQuickReplyPosition).
                            run(() async {
                              final current = await service.fetch(storeId);
                              await service.add(
                                storeId,
                                text,
                                position: nextQuickReplyPosition(current),
                              );
                            });
                          },
                    child: Text(s.add),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
