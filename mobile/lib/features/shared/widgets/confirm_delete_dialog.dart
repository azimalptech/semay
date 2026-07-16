import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n.dart';
import '../../../core/theme.dart';

/// Figma "Delete post?" confirmation — used before any destructive post/story
/// delete, never on a bare tap.
Future<bool> confirmDelete(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String body,
}) async {
  final s = ref.read(l10nProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(s.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(s.delete),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
