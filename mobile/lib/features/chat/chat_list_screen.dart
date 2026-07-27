import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/json_ext.dart';
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
      parseTimestamp(data[asAdmin ? 'hiddenByAdminAt' : 'hiddenByUserAt']);
  if (hiddenAt == null) return false;
  final lastAt = parseTimestamp(data['lastMessageAt']);
  return lastAt == null || lastAt.compareTo(hiddenAt) <= 0;
}

/// Coordinates every _SwipeToDelete row on the chat list (one instance per
/// screen, owned by ChatListScreen) so:
/// - opening one closes whichever other row is currently open (each row used
///   to track its own open/closed state independently, so swiping several
///   left in a row left them all open at once);
/// - a tap anywhere on the list closes an open row instead of also
///   performing that tap's own action;
/// - a tap on the AppBar/anywhere else on this screen, or navigating away
///   from the Chat tab entirely (see ChatListScreen's VisibilityDetector —
///   this screen is kept alive across bottom-nav tab switches, so nothing
///   else would ever reset this), also closes it. Swiping open a row and
///   leaving it open forever otherwise was the actual bug report.
class _SwipeCoordinator extends ChangeNotifier {
  String? _openId;
  String? get openId => _openId;

  void open(String id) {
    if (_openId == id) return;
    _openId = id;
    notifyListeners();
  }

  void closeIfOpen(String id) {
    if (_openId != id) return;
    _openId = null;
    notifyListeners();
  }

  void closeAll() {
    if (_openId == null) return;
    _openId = null;
    notifyListeners();
  }
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

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  final _swipeCoordinator = _SwipeCoordinator();

  @override
  void dispose() {
    _swipeCoordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(appRoleProvider).value;
    final isAdmin = role == AppRole.admin || role == AppRole.superadmin;

    // Kept alive across bottom-nav tab switches (see router.dart's
    // _KeepAlivePage) — nothing else would ever tell an open swipe to close
    // when the user navigates to another tab, so this screen needs to notice
    // for itself. Any drop below fully visible (not just fully gone) counts:
    // by the time a tab switch away is even *noticeable* mid-swipe, the open
    // row should already be closing, not wait until it's completely offscreen.
    return VisibilityDetector(
      key: const Key('chat-list-screen'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 1.0) _swipeCoordinator.closeAll();
      },
      child: GestureDetector(
        // translucent — lets this coexist with every descendant's own taps
        // (row navigation, the AppBar) rather than stealing them; it only
        // adds "also close whatever's open" on top, which is a no-op via
        // closeAll() when nothing is.
        behavior: HitTestBehavior.translucent,
        onTap: _swipeCoordinator.closeAll,
        child: Scaffold(
          appBar: AppBar(title: Text(ref.watch(l10nProvider).chat)),
          body: isAdmin
              ? _AdminChatList(coordinator: _swipeCoordinator)
              : _UserChatList(coordinator: _swipeCoordinator),
        ),
      ),
    );
  }
}

/// Shows every active store by default (not just ones with an existing
/// conversation) — stores already messaged sort to the top by recency same
/// as before; stores with no messages yet follow, alphabetically. Tapping
/// one of those lazily creates the chat doc (ChatService.createOrGetChat)
/// instead of requiring a first message to exist before the thread shows up.
class _UserChatList extends ConsumerStatefulWidget {
  const _UserChatList({required this.coordinator});

  final _SwipeCoordinator coordinator;

  @override
  ConsumerState<_UserChatList> createState() => _UserChatListState();
}

class _UserChatListState extends ConsumerState<_UserChatList> {
  @override
  Widget build(BuildContext context) {
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
            id: chat.id,
            coordinator: widget.coordinator,
            onDelete: () =>
                _confirmAndHideChat(context, ref, chat.id, asAdmin: false),
            child: _ChatRow(
              avatarUrl: store?['avatarUrl'] as String? ?? '',
              name: store?['name'] as String? ?? '...',
              lastMessage: data['lastMessageText'] as String? ?? '',
              lastMessageAt: parseTimestamp(data['lastMessageAt']),
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
  const _AdminChatList({required this.coordinator});

  final _SwipeCoordinator coordinator;

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

  // The admin chat list is now delivered live over the store:{id}:chats
  // realtime channel (server snapshot caps at the most recent 100 per store),
  // so there's no incremental pagination to drive — the scroll listener is
  // kept only so the field wiring stays intact; it's a no-op.
  void _maybeLoadMore() {}

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
              id: chat.id,
              coordinator: widget.coordinator,
              onDelete: () =>
                  _confirmAndHideChat(context, ref, chat.id, asAdmin: true),
              child: _ChatRow(
                avatarUrl: customer?['avatarUrl'] as String? ?? '',
                name: customer?['name'] as String? ?? '...',
                lastMessage: data['lastMessageText'] as String? ?? '',
                lastMessageAt: parseTimestamp(data['lastMessageAt']),
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
  final DateTime? lastMessageAt;
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

  static String _formatDate(DateTime? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp;
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
    required this.id,
    required this.coordinator,
    required this.child,
    required this.onDelete,
  });

  /// This row's chat id — how it claims/checks ownership of "the open row"
  /// on [coordinator].
  final String id;
  final _SwipeCoordinator coordinator;
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

  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_onCoordinatorChanged);
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_onCoordinatorChanged);
    _controller.dispose();
    super.dispose();
  }

  // Some other row just claimed "open" — close this one without touching
  // the coordinator (it's already pointing at that other row).
  void _onCoordinatorChanged() {
    if (widget.coordinator.openId != widget.id && _controller.value != 0) {
      _controller.animateTo(0, curve: Curves.easeOut);
    }
  }

  void _onDragStart(DragStartDetails d) => widget.coordinator.open(widget.id);

  void _onDragUpdate(DragUpdateDetails d) {
    _controller.value = (_controller.value + d.delta.dx).clamp(
      -_revealWidth,
      0.0,
    );
  }

  void _onDragEnd(DragEndDetails d) {
    final open = _controller.value < -_revealWidth / 2;
    _controller.animateTo(open ? -_revealWidth : 0.0, curve: Curves.easeOut);
    if (open) {
      widget.coordinator.open(widget.id);
    } else {
      widget.coordinator.closeIfOpen(widget.id);
    }
  }

  void _close() {
    if (mounted) _controller.animateTo(0, curve: Curves.easeOut);
    widget.coordinator.closeIfOpen(widget.id);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        // Merged, not just _controller — a row that ISN'T open needs to
        // rebuild too when some OTHER row opens/closes, since that's what
        // decides whether this row's tap-catcher (below) is showing.
        animation: Listenable.merge([_controller, widget.coordinator]),
        builder: (context, child) {
          // A tap anywhere else while a row is open should just close it,
          // not also fire the tapped row's own action (e.g. navigating into
          // that chat) — same as swiping an open row shut, this row gets an
          // opaque catcher over its content whenever it's NOT the open one
          // but something else is.
          final someOtherRowOpen =
              !_isOpen && widget.coordinator.openId != null;
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
                      // Some other row is open — tapping this one closes
                      // that row instead of performing this row's own tap
                      // action (e.g. navigating into this chat).
                      if (someOtherRowOpen)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.coordinator.closeIfOpen(
                              widget.coordinator.openId!,
                            ),
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
