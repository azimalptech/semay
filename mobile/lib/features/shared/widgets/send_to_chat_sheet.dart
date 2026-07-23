import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../services/auth_service.dart';
import '../../../services/chat_service.dart';
import '../../../services/posts_service.dart';
import '../../chat/chat_providers.dart';
import '../../store_profile/store_profile_providers.dart';

/// "send" icon on a post card (Figma node 195:4333, "send" — not a comment
/// button, there is no comment feature).
///
/// For everyone except the post's own store admin, this sends directly to
/// that store's chat (no picker) after letting the sender type an
/// accompanying message. An admin viewing their *own* post has no single
/// obvious recipient — for them this still opens a conversation picker to
/// forward it to a specific customer.
Future<void> showSendToChatSheet(
  BuildContext context,
  WidgetRef ref, {
  required String postId,
  required String postStoreId,
  required String postCaption,
  required String postMediaUrl,
}) async {
  final role = await ref.read(appRoleProvider.future);
  final storeIds = await ref.read(storeIdsProvider.future);
  final isOwnPost =
      (role == AppRole.admin || role == AppRole.superadmin) &&
      storeIds.contains(postStoreId);

  if (!context.mounted) return;

  if (isOwnPost) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.backgroundCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _ForwardToConversationSheet(
        postId: postId,
        postCaption: postCaption,
        postMediaUrl: postMediaUrl,
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.backgroundCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => _ComposeAndSendSheet(
      postId: postId,
      postStoreId: postStoreId,
      postCaption: postCaption,
      postMediaUrl: postMediaUrl,
    ),
  );
}

/// The common path: post's own store, straight to a compose box — no
/// "which conversation" step, since there's only one possible recipient.
class _ComposeAndSendSheet extends ConsumerStatefulWidget {
  const _ComposeAndSendSheet({
    required this.postId,
    required this.postStoreId,
    required this.postCaption,
    required this.postMediaUrl,
  });

  final String postId;
  final String postStoreId;
  final String postCaption;
  final String postMediaUrl;

  @override
  ConsumerState<_ComposeAndSendSheet> createState() =>
      _ComposeAndSendSheetState();
}

class _ComposeAndSendSheetState extends ConsumerState<_ComposeAndSendSheet> {
  final _messageController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final chatId = await ref
          .read(chatServiceProvider)
          .createOrGetChat(widget.postStoreId);
      await ref
          .read(chatServiceProvider)
          .sendMessage(
            chatId,
            _messageController.text.trim(),
            senderRole: 'user',
            sharedPostId: widget.postId,
            mediaUrl: widget.postMediaUrl,
          );
      await ref.read(postsServiceProvider).recordSent(widget.postId);
      if (mounted) {
        final navigator = Navigator.of(context);
        final messenger = ScaffoldMessenger.of(context);
        final s = ref.read(l10nProvider);
        navigator.pop();
        messenger.showSnackBar(SnackBar(content: Text(s.messageSent)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final store = ref.watch(storeDocProvider(widget.postStoreId)).value;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.messageStore(store?['name'] as String? ?? ''),
                style: AppTypography.titleLarge,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: widget.postMediaUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: widget.postMediaUrl,
                              fit: BoxFit.cover,
                            )
                          : Container(color: AppColors.borderDivider),
                    ),
                  ),
                  if (widget.postCaption.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.postCaption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySmall.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: s.typeMessage,
                        filled: true,
                        fillColor: AppColors.backgroundPrimary,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send, color: AppColors.brand),
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Admin sharing their own post: which customer conversation should it go to.
class _ForwardToConversationSheet extends ConsumerWidget {
  const _ForwardToConversationSheet({
    required this.postId,
    required this.postCaption,
    required this.postMediaUrl,
  });

  final String postId;
  final String postCaption;
  final String postMediaUrl;

  Future<void> _sendTo(
    BuildContext context,
    WidgetRef ref,
    String chatId,
  ) async {
    await ref
        .read(chatServiceProvider)
        .sendMessage(
          chatId,
          postCaption,
          senderRole: 'admin',
          sharedPostId: postId,
          mediaUrl: postMediaUrl,
        );
    await ref.read(postsServiceProvider).recordSent(postId);
    if (context.mounted) {
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      final s = ref.read(l10nProvider);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(s.messageSent)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final chatsAsync = ref.watch(adminChatsProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(s.sendToChat, style: AppTypography.titleLarge),
          ),
          Flexible(
            child: chatsAsync.when(
              data: (chats) {
                if (chats.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      s.noConversationsYet,
                      style: AppTypography.bodyMedium,
                    ),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final chat in chats)
                      _ChatTile(
                        chat: chat.data(),
                        onTap: () => _sendTo(context, ref, chat.id),
                      ),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stack) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${s.failedToLoad}: $error'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  const _ChatTile({required this.chat, required this.onTap});

  final Map<String, dynamic> chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = ref.watch(userDocProvider(chat['userId'] as String)).value;
    final avatarUrl = customer?['avatarUrl'] as String? ?? '';
    final name = customer?['name'] as String? ?? '…';

    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: AppColors.backgroundPrimary,
        backgroundImage: avatarUrl.isNotEmpty
            ? CachedNetworkImageProvider(avatarUrl)
            : null,
        child: avatarUrl.isEmpty
            ? Icon(Icons.person, color: AppColors.textMuted)
            : null,
      ),
      title: Text(name, style: AppTypography.bodyMedium),
      onTap: onTap,
    );
  }
}
