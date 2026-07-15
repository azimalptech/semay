import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../store_profile/store_profile_providers.dart';
import 'chat_providers.dart';

class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(appRoleProvider).value;
    final isAdmin = role == AppRole.admin || role == AppRole.superadmin;

    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: isAdmin ? const _AdminChatList() : const _UserChatList(),
    );
  }
}

class _UserChatList extends ConsumerWidget {
  const _UserChatList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatsAsync = ref.watch(userChatsProvider);
    return chatsAsync.when(
      data: (chats) {
        if (chats.isEmpty) return const Center(child: Text('No conversations yet'));
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: chats.length,
          itemBuilder: (context, index) {
            final chat = chats[index];
            final data = chat.data();
            final store = ref.watch(storeDocProvider(data['storeId'] as String)).value;
            return _ChatRow(
              avatarUrl: store?['avatarUrl'] as String? ?? '',
              name: store?['name'] as String? ?? '...',
              lastMessage: data['lastMessageText'] as String? ?? '',
              lastMessageAt: data['lastMessageAt'] as Timestamp?,
              onTap: () => context.push('/chat/${chat.id}'),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Error: $error')),
    );
  }
}

class _AdminChatList extends ConsumerWidget {
  const _AdminChatList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatsAsync = ref.watch(adminChatsProvider);
    return chatsAsync.when(
      data: (chats) {
        if (chats.isEmpty) return const Center(child: Text('No conversations yet'));
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: chats.length,
          itemBuilder: (context, index) {
            final chat = chats[index];
            final data = chat.data();
            final customer = ref.watch(userDocProvider(data['userId'] as String)).value;
            return _ChatRow(
              avatarUrl: customer?['avatarUrl'] as String? ?? '',
              name: customer?['name'] as String? ?? '...',
              lastMessage: data['lastMessageText'] as String? ?? '',
              lastMessageAt: data['lastMessageAt'] as Timestamp?,
              onTap: () => context.push('/admin/chat/${chat.id}'),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Error: $error')),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.avatarUrl,
    required this.name,
    required this.lastMessage,
    required this.lastMessageAt,
    required this.onTap,
  });

  final String avatarUrl;
  final String name;
  final String lastMessage;
  final Timestamp? lastMessageAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _ChatAvatar(avatarUrl: avatarUrl, name: name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(name, style: AppTypography.bodyMediumSemibold),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption,
                        ),
                      ),
                      Text(_formatDate(lastMessageAt), style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatDate(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
    final now = DateTime.now();
    final isToday = date.year == now.year && date.month == now.month && date.day == now.day;
    final formatted = '${date.day} ${_months[date.month - 1]}';
    return isToday ? 'Today, $formatted' : formatted;
  }
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({required this.avatarUrl, required this.name});

  final String avatarUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    if (avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 27,
        backgroundColor: AppColors.backgroundCard,
        backgroundImage: CachedNetworkImageProvider(avatarUrl),
      );
    }
    return CircleAvatar(
      radius: 27,
      backgroundColor: AppColors.buttonMuted,
      child: Text(
        _initials(name),
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }
}
