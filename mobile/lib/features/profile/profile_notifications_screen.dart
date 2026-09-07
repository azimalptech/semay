import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_icon.dart';
import '../../core/json_ext.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import 'notifications_providers.dart';

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _dateHeader(DateTime date) => '${_months[date.month - 1]} ${date.day}';

String _timeLabel(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

class ProfileNotificationsScreen extends ConsumerStatefulWidget {
  const ProfileNotificationsScreen({super.key});

  @override
  ConsumerState<ProfileNotificationsScreen> createState() =>
      _ProfileNotificationsScreenState();
}

class _ProfileNotificationsScreenState
    extends ConsumerState<ProfileNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // The provider is REST-only and otherwise cached for the app's lifetime,
    // so a broadcast that arrived while this screen was closed (or the app
    // backgrounded) is only seen if opening the inbox refetches. Riverpod
    // keeps the previous list on screen while the refetch is in flight.
    ref.invalidate(notificationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final notificationsAsync = ref.watch(notificationsProvider);
    final docs = notificationsAsync.value ?? const [];

    // Opening the list is the "seen" signal, same as Instagram/most apps. It
    // is applied to each list the server RETURNS, not once on the first
    // build: the first build shows the cached list (see initState), and the
    // row this open fetched — the broadcast that arrived while the app was
    // away — lands afterwards. Marked once per screen, that row would stay
    // unread and the bell lit until the next open. markAllRead is a no-op
    // when nothing is unread, so the refetch it triggers does not loop.
    ref.listen(notificationsProvider, (previous, next) {
      final loaded = next.value;
      if (next.isLoading || loaded == null) return;
      ref.read(notificationsServiceProvider).markAllRead(loaded);
    });

    // Store-admin-only entry point into "request Super Admin broadcast a
    // notification" — lives here (not a separate row back on the Settings
    // screen) since it's specifically about *this* notifications surface.
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? const <String>[];
    final isAdmin =
        (role == AppRole.admin || role == AppRole.superadmin) &&
        storeIds.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.notifications),
        actions: [
          if (isAdmin)
            IconButton(
              icon: AppIcon('plus', color: AppColors.textPrimary),
              tooltip: s.requestNotification,
              onPressed: () => context.push(
                '/settings/notification-requests/${storeIds.first}',
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(notificationsProvider.future),
        // Both branches stay scrollable when short — a RefreshIndicator only
        // works over something the user can drag.
        child: docs.isEmpty
            ? CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        s.noNotificationsYet,
                        style: AppTypography.bodyMedium,
                      ),
                    ),
                  ),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: _groupedByDate(docs),
              ),
      ),
    );
  }

  List<Widget> _groupedByDate(List<NotificationDoc> docs) {
    final widgets = <Widget>[];
    String? lastHeader;
    for (final doc in docs) {
      final data = doc.data();
      final createdAt = parseTimestamp(data['createdAt']);
      final header = createdAt != null ? _dateHeader(createdAt) : '';
      if (header != lastHeader) {
        lastHeader = header;
        widgets.add(_DateHeader(label: header));
      }
      widgets.add(
        _NotificationTile(
          title: data['title'] as String? ?? '',
          body: data['body'] as String? ?? '',
          time: createdAt != null ? _timeLabel(createdAt) : '',
          unread: data['readAt'] == null,
        ),
      );
    }
    return widgets;
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.backgroundPrimary,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: AppTypography.caption,
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.title,
    required this.body,
    required this.time,
    required this.unread,
  });

  final String title;
  final String body;
  final String time;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundCard,
        border: Border(bottom: BorderSide(color: AppColors.borderDivider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodyMediumSemibold),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  time,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (unread)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
