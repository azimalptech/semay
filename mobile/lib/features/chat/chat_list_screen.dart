import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
          itemCount: chats.length,
          itemBuilder: (context, index) {
            final chat = chats[index];
            final data = chat.data();
            final store = ref.watch(storeDocProvider(data['storeId'] as String)).value;
            final unread = data['unreadByUser'] as int? ?? 0;
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.storefront)),
              title: Text(store?['name'] as String? ?? '...'),
              subtitle: Text(
                data['lastMessageText'] as String? ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: unread > 0 ? CircleAvatar(radius: 10, child: Text('$unread')) : null,
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
          itemCount: chats.length,
          itemBuilder: (context, index) {
            final chat = chats[index];
            final data = chat.data();
            final customer = ref.watch(userDocProvider(data['userId'] as String)).value;
            final unread = data['unreadByAdmin'] as int? ?? 0;
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(customer?['name'] as String? ?? '...'),
              subtitle: Text(
                data['lastMessageText'] as String? ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: unread > 0 ? CircleAvatar(radius: 10, child: Text('$unread')) : null,
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
