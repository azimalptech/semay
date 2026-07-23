import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../shared/widgets/confirm_delete_dialog.dart';
import '../shared/widgets/error_state_view.dart';
import '../store_profile/store_profile_providers.dart';
import 'chat_providers.dart';

/// A chat is soft-hidden for one side (see ChatService.hideChat) until a
/// newer message arrives — i.e. its `lastMessageAt` moves past the moment
/// they hid it. No last message at all keeps it hidden.
bool _isHiddenForSide(Map<String, dynamic> data, {required bool asAdmin}) {
  final hiddenAt =
      data[asAdmin ? 'hiddenByAdminAt' : 'hiddenByUserAt'] as Timestamp?;
  if (hiddenAt == null) return false;
  final lastAt = data['lastMessageAt'] as Timestamp?;
  return lastAt == null || lastAt.compareTo(hiddenAt) <= 0;
}

Future<void> _confirmAndHideChat(
  BuildContext context,
  WidgetRef ref,
  String chatId, {
  required bool asAdmin,
}) async {
  final s = ref.read(l10nProvider);
  final confirmed = await confirmDelete(
    context,
    ref,
    title: s.deleteChatTitle,
    body: s.deleteChatBody,
  );
  if (!confirmed) return;
  await ref.read(chatServiceProvider).hideChat(chatId, asAdmin: asAdmin);
}

class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(appRoleProvider).value;
    final isAdmin = role == AppRole.admin || role == AppRole.superadmin;

    return Scaffold(
      appBar: AppBar(title: Text(ref.watch(l10nProvider).chat)),
      body: isAdmin ? const _AdminChatList() : const _UserChatList(),
    );
  }
}

/// Shows every active store by default (not just ones with an existing
/// conversation) — stores already messaged sort to the top by recency same
/// as before; stores with no messages yet follow, alphabetically. Tapping
/// one of those lazily creates the chat doc (ChatService.createOrGetChat)
/// instead of requiring a first message to exist before the thread shows up.
class _UserChatList extends ConsumerWidget {
  const _UserChatList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatsAsync = ref.watch(userChatsProvider);
    final storesAsync = ref.watch(activeStoresProvider);
    if (!chatsAsync.hasValue || !storesAsync.hasValue) {
      if (chatsAsync.hasError) {
        return ErrorStateView(onRetry: () => ref.invalidate(userChatsProvider));
      }
      if (storesAsync.hasError) {
        return ErrorStateView(
          onRetry: () => ref.invalidate(activeStoresProvider),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final chats = chatsAsync.value!
        .where((c) => !_isHiddenForSide(c.data(), asAdmin: false))
        .toList();
    final chatByStoreId = {
      for (final c in chats) c.data()['storeId'] as String: c,
    };
    final storesWithoutChat =
        storesAsync.value!
            .where((s) => !chatByStoreId.containsKey(s.id))
            .toList()
          ..sort(
            (a, b) => (a.data()['name'] as String? ?? '').compareTo(
              b.data()['name'] as String? ?? '',
            ),
          );

    if (chats.isEmpty && storesWithoutChat.isEmpty) {
      return Center(child: Text(ref.watch(l10nProvider).noConversationsYet));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: chats.length + storesWithoutChat.length,
      itemBuilder: (context, index) {
        if (index < chats.length) {
          final chat = chats[index];
          final data = chat.data();
          final store = ref
              .watch(storeDocProvider(data['storeId'] as String))
              .value;
          return _SwipeToDelete(
            key: ValueKey('chat-${chat.id}'),
            onDelete: () =>
                _confirmAndHideChat(context, ref, chat.id, asAdmin: false),
            child: _ChatRow(
              avatarUrl: store?['avatarUrl'] as String? ?? '',
              name: store?['name'] as String? ?? '...',
              lastMessage: data['lastMessageText'] as String? ?? '',
              lastMessageAt: data['lastMessageAt'] as Timestamp?,
              unreadCount: data['unreadByUser'] as int? ?? 0,
              onTap: () => context.push('/chat/${chat.id}'),
            ),
          );
        }
        final storeDoc = storesWithoutChat[index - chats.length];
        final data = storeDoc.data();
        return _ChatRow(
          avatarUrl: data['avatarUrl'] as String? ?? '',
          name: data['name'] as String? ?? '',
          lastMessage: '',
          lastMessageAt: null,
          unreadCount: 0,
          onTap: () async {
            final chatId = await ref
                .read(chatServiceProvider)
                .createOrGetChat(storeDoc.id);
            if (context.mounted) context.push('/chat/$chatId');
          },
        );
      },
    );
  }
}

class _AdminChatList extends ConsumerStatefulWidget {
  const _AdminChatList();

  @override
  ConsumerState<_AdminChatList> createState() => _AdminChatListState();
}

class _AdminChatListState extends ConsumerState<_AdminChatList> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _controller.removeListener(_maybeLoadMore);
    _controller.dispose();
    super.dispose();
  }

  // Grow the window a page at a time as the admin nears the bottom. Only when
  // the current page came back full (loaded >= limit) — a short page means
  // we've already reached the oldest conversation, so there's nothing more to
  // fetch and the limit shouldn't keep climbing past what exists.
  void _maybeLoadMore() {
    if (_controller.position.pixels <
        _controller.position.maxScrollExtent - 400) {
      return;
    }
    final limit = ref.read(adminChatLimitProvider);
    final loaded = ref.read(adminChatsProvider).value?.length ?? 0;
    if (loaded >= limit) {
      ref.read(adminChatLimitProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(adminChatsProvider);
    return chatsAsync.when(
      data: (allChats) {
        final chats = allChats
            .where((c) => !_isHiddenForSide(c.data(), asAdmin: true))
            .toList();
        if (chats.isEmpty) {
          return Center(
            child: Text(ref.watch(l10nProvider).noConversationsYet),
          );
        }
        return ListView.builder(
          controller: _controller,
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: chats.length,
          itemBuilder: (context, index) {
            final chat = chats[index];
            final data = chat.data();
            final customer = ref
                .watch(userDocProvider(data['userId'] as String))
                .value;
            return _SwipeToDelete(
              key: ValueKey('chat-${chat.id}'),
              onDelete: () =>
                  _confirmAndHideChat(context, ref, chat.id, asAdmin: true),
              child: _ChatRow(
                avatarUrl: customer?['avatarUrl'] as String? ?? '',
                name: customer?['name'] as String? ?? '...',
                lastMessage: data['lastMessageText'] as String? ?? '',
                lastMessageAt: data['lastMessageAt'] as Timestamp?,
                unreadCount: data['unreadByAdmin'] as int? ?? 0,
                onTap: () => context.push('/admin/chat/${chat.id}'),
              ),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) =>
          ErrorStateView(onRetry: () => ref.invalidate(adminChatsProvider)),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.avatarUrl,
    required this.name,
    required this.lastMessage,
    required this.lastMessageAt,
    required this.unreadCount,
    required this.onTap,
  });

  final String avatarUrl;
  final String name;
  final String lastMessage;
  final Timestamp? lastMessageAt;
  final int unreadCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasUnread = unreadCount > 0;
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
                          style: AppTypography.caption.copyWith(
                            color: hasUnread ? AppColors.textPrimary : null,
                            fontWeight: hasUnread ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      Text(
                        _formatDate(lastMessageAt),
                        style: AppTypography.caption.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (hasUnread) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                constraints: const BoxConstraints(minWidth: 22),
                decoration: BoxDecoration(
                  color: AppColors.brand,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : '$unreadCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _formatDate(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
    final now = DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;
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
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }
}

/// Swipe a chat row left to reveal a trash action; tapping it runs [onDelete]
/// (which shows the confirm dialog). A self-contained reveal-then-tap slider —
/// deliberately not swipe-to-dismiss, so deletion always goes through an
/// explicit confirmation, and no extra package is pulled in. Keyed by chat id
/// at the call site so ListView recycling never carries an open swipe onto a
/// different row.
class _SwipeToDelete extends StatefulWidget {
  const _SwipeToDelete({
    super.key,
    required this.child,
    required this.onDelete,
  });

  final Widget child;
  final Future<void> Function() onDelete;

  @override
  State<_SwipeToDelete> createState() => _SwipeToDeleteState();
}

class _SwipeToDeleteState extends State<_SwipeToDelete>
    with SingleTickerProviderStateMixin {
  static const _revealWidth = 76.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    lowerBound: -_revealWidth,
    upperBound: 0,
    value: 0,
  );

  bool get _isOpen => _controller.value < 0;

  void _onDragUpdate(DragUpdateDetails d) {
    _controller.value = (_controller.value + d.delta.dx).clamp(
      -_revealWidth,
      0.0,
    );
  }

  void _onDragEnd(DragEndDetails d) {
    final open = _controller.value < -_revealWidth / 2;
    _controller.animateTo(open ? -_revealWidth : 0.0, curve: Curves.easeOut);
  }

  void _close() {
    if (mounted) _controller.animateTo(0, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Stack(
            children: [
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () async {
                      await widget.onDelete();
                      // onDelete may hide the chat, removing this row (and
                      // disposing us) — _close() no-ops if we're gone.
                      _close();
                    },
                    child: Container(
                      width: _revealWidth,
                      color: AppColors.error,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(_controller.value, 0),
                child: ColoredBox(
                  color: AppColors.backgroundPrimary,
                  child: Stack(
                    children: [
                      child!,
                      // While open, a tap anywhere on the row closes the swipe
                      // rather than opening the chat.
                      if (_isOpen)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _close,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}
