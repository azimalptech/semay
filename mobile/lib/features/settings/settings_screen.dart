import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/theme_provider.dart';
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
    final profile = ref.watch(userProfileProvider).value;
    final name = profile?['name'] as String? ?? '';
    final phone = profile?['phone'] as String? ?? '';
    final avatarUrl = profile?['avatarUrl'] as String? ?? '';

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(title: Text(s.settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _SettingsCard(
            children: [
              ListTile(
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.brand,
                  backgroundImage: avatarUrl.isNotEmpty
                      ? CachedNetworkImageProvider(avatarUrl)
                      : null,
                  child: avatarUrl.isEmpty
                      ? Text(
                          _initials(name),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : null,
                ),
                title: Text(
                  name.isNotEmpty ? name : phone,
                  style: AppTypography.bodyMediumSemibold,
                ),
                subtitle: name.isNotEmpty
                    ? Text(
                        phone,
                        style: AppTypography.bodySmall.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      )
                    : null,
                trailing: AppIcon('chevron_right', color: AppColors.textMuted),
                onTap: () => context.push('/settings/edit-profile'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            children: [
              _SettingsTile(
                icon: const AppIcon('bell'),
                iconColor: const Color(0xFF34A853),
                title: s.notifications,
                onTap: () => context.push('/settings/notifications'),
                trailingExtra: isAdmin
                    ? IconButton(
                        icon: AppIcon('plus', color: AppColors.textMuted),
                        tooltip: s.requestNotification,
                        onPressed: () => context.push(
                          '/settings/notification-requests/$storeId',
                        ),
                      )
                    : null,
              ),
              _SettingsTile(
                icon: const AppIcon('heart'),
                iconColor: AppColors.error,
                title: s.likes,
                onTap: () => context.push('/settings/liked'),
              ),
              _SettingsTile(
                icon: const AppIcon('bookmark'),
                iconColor: const Color(0xFF2E8FF4),
                title: s.saved,
                onTap: () => context.push('/settings/saved'),
              ),
              if (isAdmin) ...[
                _SettingsTile(
                  icon: const Icon(Icons.refresh),
                  iconColor: const Color(0xFFF4832E),
                  title: s.quickReplies,
                  onTap: () => context.push('/settings/quick-replies/$storeId'),
                ),
                _SettingsTile(
                  icon: const Icon(Icons.shopping_bag_outlined),
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
                icon: const AppIcon('globe'),
                iconColor: AppColors.brand,
                title: s.language,
                trailingText: _languageLabel(
                  ref.watch(userProfileProvider).value?['language'] as String?,
                ),
                onTap: () => _showLanguageSheet(context, ref),
              ),
              _SettingsSwitchTile(
                icon: const Icon(Icons.dark_mode_outlined),
                iconColor: const Color(0xFF5C5C5C),
                title: s.darkMode,
                value: ref.watch(darkModeProvider),
                onChanged: (value) => setDarkMode(ref, value),
              ),
              _SettingsTile(
                icon: const AppIcon('info'),
                iconColor: const Color(0xFF2E8FF4),
                title: s.privacyPolicy,
              ),
              _SettingsTile(
                icon: const AppIcon('phone'),
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
              icon: const AppIcon('logout', color: AppColors.error),
              label: Text(
                s.logout,
                style: const TextStyle(color: AppColors.error),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: AppColors.backgroundCard,
                minimumSize: const Size.fromHeight(48),
                side: BorderSide(color: AppColors.borderDivider),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                s.appVersion,
                style: AppTypography.caption,
                textAlign: TextAlign.center,
              ),
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

String _initials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  final first = words.first[0];
  final second = words.length > 1 ? words[1][0] : '';
  return (first + second).toUpperCase();
}

String _languageLabel(String? code) => code == 'ru' ? 'Русский' : 'Türkmen';

Future<void> _showLanguageSheet(BuildContext context, WidgetRef ref) async {
  final s = ref.read(l10nProvider);
  final current =
      ref.read(userProfileProvider).value?['language'] as String? ?? 'tk';

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
                  icon: AppIcon('close', color: AppColors.textPrimary),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          for (final entry in const {'tk': 'Türkmen', 'ru': 'Русский'}.entries)
            ListTile(
              title: Text(entry.value, style: AppTypography.bodyMedium),
              trailing: current == entry.key
                  ? const AppIcon('check', color: AppColors.brand)
                  : null,
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
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(s.cancel),
        ),
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
    this.trailingExtra,
  });

  /// An `Icon(Icons.xxx)` or `AppIcon('xxx')` — this row mixes both
  /// Material fallbacks and the app's own custom asset set, so it takes an
  /// already-built glyph rather than an `IconData` that can only ever be
  /// the former.
  final Widget icon;
  final Color iconColor;
  final String title;
  final String? trailingText;
  final VoidCallback? onTap;

  /// An extra tappable slot before the chevron — only the Notifications
  /// row's admin-only "+" (request a broadcast notification) uses this so
  /// far, not worth a whole separate row just for one small icon button.
  final Widget? trailingExtra;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: iconColor,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Center(
          child: IconTheme.merge(
            data: const IconThemeData(size: 18, color: Colors.white),
            child: icon,
          ),
        ),
      ),
      title: Text(title, style: AppTypography.bodyMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                trailingText!,
                style: AppTypography.bodySmall.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ?trailingExtra,
          AppIcon('chevron_right', color: AppColors.textMuted),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final Widget icon;
  final Color iconColor;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: iconColor.withValues(alpha: 0.12),
        child: IconTheme.merge(
          data: IconThemeData(size: 18, color: iconColor),
          child: icon,
        ),
      ),
      title: Text(title, style: AppTypography.bodyMedium),
      trailing: Switch(
        value: value,
        activeThumbColor: AppColors.brand,
        onChanged: onChanged,
      ),
      onTap: () => onChanged(!value),
    );
  }
}
