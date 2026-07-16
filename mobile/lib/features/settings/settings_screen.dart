import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

/// Figma "Settings" frame — reached from the bottom-nav "user" tab for both
/// User and Store Admin (same frame, admin sees two extra rows: Quick
/// Replies + Orders, both store-scoped so only shown when [storeId] is set).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.storeId});

  /// Null for User role. Set for Admin role (their first storeId).
  final String? storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = storeId != null;
    final s = ref.watch(l10nProvider);

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _SettingsCard(
            children: [
              _SettingsTile(
                icon: Icons.notifications_none,
                iconColor: const Color(0xFF34A853),
                title: s.notifications,
                onTap: () => context.push('/settings/notifications'),
              ),
              _SettingsTile(
                icon: Icons.favorite_border,
                iconColor: AppColors.error,
                title: s.likes,
                onTap: () => context.push('/settings/liked'),
              ),
              _SettingsTile(
                icon: Icons.bookmark_border,
                iconColor: const Color(0xFF2E8FF4),
                title: s.saved,
                onTap: () => context.push('/settings/saved'),
              ),
              if (isAdmin) ...[
                _SettingsTile(
                  icon: Icons.refresh,
                  iconColor: const Color(0xFFF4832E),
                  title: s.quickReplies,
                  onTap: () => context.push('/settings/quick-replies/$storeId'),
                ),
                _SettingsTile(
                  icon: Icons.shopping_bag_outlined,
                  iconColor: const Color(0xFFF4832E),
                  title: s.orders,
                  onTap: () => context.push('/settings/orders/$storeId'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            children: [
              _SettingsTile(
                icon: Icons.language,
                iconColor: AppColors.brand,
                title: s.language,
                trailingText:
                    _languageLabel(ref.watch(userProfileProvider).value?['language'] as String?),
                onTap: () => _showLanguageSheet(context, ref),
              ),
              _SettingsTile(
                icon: Icons.info_outline,
                iconColor: const Color(0xFF2E8FF4),
                title: s.privacyPolicy,
              ),
              _SettingsTile(
                icon: Icons.call_outlined,
                iconColor: const Color(0xFF34A853),
                title: s.contactUs,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => _confirmLogout(context, ref),
              icon: const Icon(Icons.logout, color: AppColors.error),
              label: Text(s.logout, style: const TextStyle(color: AppColors.error)),
              style: OutlinedButton.styleFrom(
                backgroundColor: AppColors.backgroundCard,
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: AppColors.borderDivider),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(s.appVersion, style: AppTypography.caption, textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}

/// Figma "Settings": each group of rows sits in its own white rounded card
/// over the beige page background, with a hairline divider between rows.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderDivider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 56),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

String _languageLabel(String? code) => code == 'ru' ? 'Русский' : 'Türkmen';

Future<void> _showLanguageSheet(BuildContext context, WidgetRef ref) async {
  final s = ref.read(l10nProvider);
  final current = ref.read(userProfileProvider).value?['language'] as String? ?? 'tk';

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.backgroundCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(s.selectLanguage, style: AppTypography.titleLarge),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textPrimary),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          for (final entry in const {'tk': 'Türkmen', 'ru': 'Русский'}.entries)
            ListTile(
              title: Text(entry.value, style: AppTypography.bodyMedium),
              trailing: current == entry.key ? const Icon(Icons.check, color: AppColors.brand) : null,
              onTap: () async {
                final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
                if (uid != null) {
                  await ref
                      .read(firestoreProvider)
                      .collection('users')
                      .doc(uid)
                      .update({'language': entry.key});
                }
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
  final s = ref.read(l10nProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(s.logout),
      content: Text(s.logoutConfirm),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(s.cancel)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(s.logout),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(authServiceProvider).signOut();
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.trailingText,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? trailingText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: iconColor.withValues(alpha: 0.12),
        child: Icon(icon, size: 18, color: iconColor),
      ),
      title: Text(title, style: AppTypography.bodyMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(trailingText!,
                  style: AppTypography.bodySmall.copyWith(color: AppColors.textSecondary)),
            ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
      onTap: onTap,
    );
  }
}
