import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n.dart';
import '../../../services/posts_service.dart';

/// Instagram-style post edit — caption only, media stays as published.
Future<void> showEditCaptionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String postId,
  required String currentCaption,
}) async {
  final s = ref.read(l10nProvider);
  // Read once, up front: the dialog can outlive the calling widget's build
  // (e.g. the post doc stream emits again, or the caller scrolls out of a
  // recycled list), which invalidates `ref` for later use inside the
  // async onPressed below. postsServiceProvider is a plain stable
  // instance, so capturing it now sidesteps that entirely.
  final postsService = ref.read(postsServiceProvider);
  final controller = TextEditingController(text: currentCaption);
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(s.editCaption),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(labelText: s.caption),
        ),
        actions: [
          TextButton(
            onPressed: submitting
                ? null
                : () => Navigator.of(dialogContext).pop(),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () async {
                    setState(() => submitting = true);
                    try {
                      await postsService.updateCaption(
                        postId,
                        controller.text.trim(),
                      );
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    } catch (e) {
                      setState(() => submitting = false);
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(
                          dialogContext,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
            child: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.save),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
}
