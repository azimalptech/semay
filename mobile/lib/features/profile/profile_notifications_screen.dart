import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
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
  bool _markedRead = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final notificationsAsync = ref.watch(notificationsProvider);
    final docs = notificationsAsync.value ?? const [];

    // Opening the list is the "seen" signal, same as Instagram/most apps —
    // marks everything currently loaded as read once, not on every rebuild.
    if (!_markedRead && docs.isNotEmpty) {
      _markedRead = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(notificationsServiceProvider).markAllRead(docs);
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(s.notifications)),
      body: docs.isEmpty
          ? Center(
              child: Text(
                s.noNotificationsYet,
                style: AppTypography.bodyMedium,
              ),
            )
          : ListView(children: _groupedByDate(docs)),
    );
  }

  List<Widget> _groupedByDate(List<NotificationDoc> docs) {
    final widgets = <Widget>[];
    String? lastHeader;
    for (final doc in docs) {
      final data = doc.data();
      final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
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
          unread: data['read'] != true,
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
