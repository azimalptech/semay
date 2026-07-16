import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';

// TODO(phase-5-followup): docs/03_CLOUD_FUNCTIONS_API.md's triggers send FCM
// push directly (no persisted notification history collection in
// docs/02_DATA_MODEL.md yet) — this is an honest empty state, not a stub
// pending a real `notifications` collection design.
class ProfileNotificationsScreen extends ConsumerWidget {
  const ProfileNotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.notifications)),
      body: Center(
        child: Text(s.noNotificationsYet, style: AppTypography.bodyMedium),
      ),
    );
  }
}
