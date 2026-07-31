import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_icon.dart';
import '../../core/json_ext.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../../services/quick_replies_service.dart';
import '../shared/post_interaction_providers.dart';
import '../store_profile/store_profile_providers.dart';
import 'accept_order_sheet.dart';
import 'chat_providers.dart';

/// How fresh a typing heartbeat must be to show the indicator, and the
/// minimum gap between heartbeat writes while composing.
const _typingFreshness = Duration(seconds: 5);
const _typingWriteGap = Duration(seconds: 2);

class ChatThreadScreen extends ConsumerStatefulWidget {
  const ChatThreadScreen({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _hasText = false;
  bool _isAdminHere = false;
  DateTime _lastTypingWrite = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _staleness;
  bool _isAttaching = false;
  // Messages load oldest-first (see chatMessagesProvider), so a plain
  // ListView opens scrolled to the top — jump straight to the newest
  // message on first load, then smoothly follow along as new ones arrive.
  int _lastMessageCount = -1;
  // Set by swiping a bubble (see _SwipeToReply's onReply); shown as a
  // preview strip above the composer, cleared on send/cancel.
  Map<String, String?>? _replyingTo;

  void _scrollToBottom({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _settleScrollToBottom(animate: animate, attemptsLeft: 6),
    );
  }

  // ListView.builder only lays out/measures items actually near the current
  // viewport on a given frame — right after opening a thread, the viewport
  // is still sitting at its default (top/oldest) position, so
  // maxScrollExtent is an *estimate* extrapolated from whichever few oldest
  // items happened to get built, not the true end. If bubble heights vary
  // (an image, a reply quote, a longer message near the end), jumping to
  // that estimate lands short of the real bottom — which is what "opens
  // somewhere in the middle, have to scroll down" was: a one-shot jump to a
  // guess. Landing the jump actually builds/measures the now-visible items,
  // which can move the true end further — so re-check next frame and jump
  // again if it moved, until two consecutive frames agree (or attempts run
  // out). Only the first hop honors [animate]; every retry is an instant
  // jump so they don't stack visible animations.
  void _settleScrollToBottom({
    required bool animate,
    required int attemptsLeft,
  }) {
    if (!mounted || !_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        max,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(max);
    }
    if (attemptsLeft <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if ((_scrollController.position.maxScrollExtent - max).abs() > 1) {
        _settleScrollToBottom(animate: false, attemptsLeft: attemptsLeft - 1);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Read by the server's sendChatPush to suppress a push notification for a
    // chat the recipient already has open — see chat_service.dart's
    // setActiveChat and that function's comment.
    ref.read(chatServiceProvider).setActiveChat(widget.chatId);
    _controller.addListener(_onTextChanged);
    // Re-evaluates typing-indicator freshness so it disappears when the other
    // side goes quiet without another snapshot arriving.
    _staleness = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  // A backgrounded app still has this screen mounted in Flutter's tree, but
  // the user obviously isn't looking at it — clear activeChatId so push
  // notifications resume, and restore it on return (as long as this screen
  // is still the one on top; if they navigated away first, dispose() has
  // already cleared it and this would just needlessly reset it back).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final service = ref.read(chatServiceProvider);
    if (state == AppLifecycleState.resumed) {
      service.setActiveChat(widget.chatId);
    } else {
      service.setActiveChat(null);
    }
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);

    if (hasText &&
        DateTime.now().difference(_lastTypingWrite) > _typingWriteGap) {
      _lastTypingWrite = DateTime.now();
      ref
          .read(chatServiceProvider)
          .setTyping(widget.chatId, asAdmin: _isAdminHere, isTyping: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(chatServiceProvider).setActiveChat(null);
    _staleness?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Runs on every messages emission while this screen is mounted, not just
  // once on open — a message arriving while the thread is already open
  // needs to land as read too, not sit at "delivered" until the user
  // backs out and back in. markMessagesRead/markThreadRead both no-op
  // cheaply once already applied (see chat_service.dart), so calling this
  // on every rebuild is fine, not just wasteful-looking.
  void _syncReadStatus(List<ChatDoc> messages, bool isAdmin, int myUnread) {
    final counterpartRole = isAdmin ? 'user' : 'admin';
    // Only their still-unread messages (readAt == null) actually need a receipt.
    final hasUnreadFromThem = messages.any(
      (m) =>
          m.data()['senderRole'] == counterpartRole &&
          m.data()['readAt'] == null,
    );
    // Nothing to mark → do NOT POST. A receipts call re-publishes the thread,
    // which re-enters build(); POSTing unconditionally here (as it did before)
    // turned that into a rebuild storm — one receipts round-trip per frame.
    // Gating on real unread makes it self-terminate: after the single call
    // below lands, their messages carry readAt and myUnread is 0, so the next
    // build returns here early.
    if (!hasUnreadFromThem && myUnread == 0) return;
    // One /receipts call marks their messages read AND clears my unread badge
    // (server markReceipts does both), so a single POST replaces the old two.
    ref.read(chatServiceProvider).markThreadRead(widget.chatId, asAdmin: isAdmin);
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final service = ref.read(chatServiceProvider);
    final replyingTo = _replyingTo;
    service.sendMessage(
      widget.chatId,
      text,
      senderRole: _isAdminHere ? 'admin' : 'user',
      replyToMessageId: replyingTo?['messageId'],
      replyToText: replyingTo?['text'],
      replyToSenderRole: replyingTo?['senderRole'],
    );
    service.setTyping(widget.chatId, asAdmin: _isAdminHere, isTyping: false);
    _lastTypingWrite = DateTime.fromMillisecondsSinceEpoch(0);
    _controller.clear();
    if (replyingTo != null) setState(() => _replyingTo = null);
  }

  void _startReply(ChatDoc message) {
    final data = message.data();
    final text = data['text'] as String? ?? '';
    final preview = text.isNotEmpty
        ? text
        : (data['mediaType'] != null
              ? '📎'
              : (data['sharedPostId'] != null ? '📷' : ''));
    setState(() {
      _replyingTo = {
        'messageId': message.id,
        'text': preview,
        'senderRole': data['senderRole'] as String?,
      };
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _attachMedia() async {
    if (_isAttaching) return;
    final file = await ImagePicker().pickMedia();
    if (file == null || !mounted) return;

    final mime = file.mimeType ?? '';
    final name = file.name.toLowerCase();
    final isVideo =
        mime.startsWith('video/') ||
        name.endsWith('.mp4') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm');
    final mediaType = isVideo ? 'video' : 'image';

    setState(() => _isAttaching = true);
    try {
      final service = ref.read(chatServiceProvider);
      final url = await service.uploadChatMedia(
        chatId: widget.chatId,
        file: file,
        mediaType: mediaType,
      );
      await service.sendMessage(
        widget.chatId,
        '',
        senderRole: _isAdminHere ? 'admin' : 'user',
        mediaUrl: url,
        mediaType: mediaType,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _isAttaching = false);
    }
  }

  static bool _isFresh(DateTime? at) =>
      at != null && DateTime.now().difference(at) < _typingFreshness;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final chat = ref.watch(chatDocProvider(widget.chatId)).value;
    final myUid = ref.watch(authStateChangesProvider).value?.uid;
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isAdminHere =
        (role == AppRole.admin || role == AppRole.superadmin) &&
        chat != null &&
        storeIds.contains(chat['storeId']);
    _isAdminHere = isAdminHere;
    // This side's unread badge count — gates the read-receipt sync below so it
    // fires only when there's something to clear (see _syncReadStatus).
    final myUnread =
        (chat?[isAdminHere ? 'unreadByAdmin' : 'unreadByUser'] as int?) ?? 0;

    final store = chat != null
        ? ref.watch(storeDocProvider(chat['storeId'] as String)).value
        : null;
    final customer = chat != null
        ? ref.watch(userDocProvider(chat['userId'] as String)).value
        : null;
    final title = isAdminHere
        ? (customer?['name'] as String? ?? '…')
        : (store?['name'] as String? ?? '…');

    // Counterpart's typing heartbeat, from the chat doc.
    final counterpartTyping = _isFresh(
      parseTimestamp(chat?[isAdminHere ? 'typingUserAt' : 'typingAdminAt']),
    );
    final isMuted =
        (chat?[isAdminHere ? 'mutedByAdmin' : 'mutedByUser'] as bool?) ?? false;

    final messagesAsync = ref.watch(mergedChatMessagesProvider(widget.chatId));

    final storeId = chat?['storeId'] as String?;
    // Only the customer side taps through to the store's profile — the
    // title here shows the *counterpart's* name (store for a customer,
    // customer for a store admin), and there's no equivalent profile screen
    // to open for a customer name.
    final canOpenStoreProfile = !isAdminHere && storeId != null;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          // opaque, not the GestureDetector default (deferToChild) — a Row
          // sized to its content only paints across its own tight bounding
          // box, so deferToChild would leave any gap between/around the
          // avatar and text as a dead zone that looks tappable (it's inside
          // the visible AppBar title strip) but never actually registers a
          // hit. opaque claims the whole padded rectangle below regardless
          // of what's actually painted in it.
          behavior: HitTestBehavior.opaque,
          onTap: canOpenStoreProfile
              ? () {
                  debugPrint(
                    'chat_thread_screen: store title tapped, storeId=$storeId',
                  );
                  context.push('/store/$storeId');
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              // No mainAxisSize.min here (was previously set) — that made
              // this Row report only its content's own intrinsic width, so
              // a long name rendered at full width and visually overlapped
              // the actions (mute/call icons) instead of stopping before
              // them. Defaulting to max fills the title's actual available
              // width, which is what lets the Expanded below give the name
              // Text a real width cap to ellipsize against.
              children: [
                if (canOpenStoreProfile) ...[
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.buttonMuted,
                    backgroundImage:
                        (store?['avatarUrl'] as String? ?? '').isNotEmpty
                        ? CachedNetworkImageProvider(
                            store!['avatarUrl'] as String,
                          )
                        : null,
                    child: (store?['avatarUrl'] as String? ?? '').isEmpty
                        ? Icon(
                            Icons.storefront,
                            size: 16,
                            color: AppColors.textMuted,
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (counterpartTyping)
                        Text(
                          s.typing,
                          style: AppTypography.caption.copyWith(
                            color: AppColors.brand,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              isMuted
                  ? Icons.notifications_off_outlined
                  : Icons.notifications_outlined,
              color: AppColors.textPrimary,
            ),
            onPressed: () {
              ref
                  .read(chatServiceProvider)
                  .setChatMuted(
                    widget.chatId,
                    asAdmin: isAdminHere,
                    muted: !isMuted,
                  );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    isMuted ? s.notificationsUnmuted : s.notificationsMuted,
                  ),
                ),
              );
            },
            tooltip: isMuted ? s.unmuteNotifications : s.muteNotifications,
          ),
          Builder(
            builder: (context) {
              final counterpartData = isAdminHere ? customer : store;
              final counterpartPhone = counterpartData?['phone'] as String?;
              return IconButton(
                icon: AppIcon('phone', color: AppColors.textPrimary),
                onPressed:
                    (counterpartPhone == null || counterpartPhone.isEmpty)
                    ? null
                    : () async {
                        final uri = Uri(scheme: 'tel', path: counterpartPhone);
                        if (!await launchUrl(uri) && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(s.couldNotOpenDialer)),
                          );
                        }
                      },
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.length != _lastMessageCount) {
                  final isFirstLoad = _lastMessageCount == -1;
                  if (!isFirstLoad && messages.isNotEmpty) {
                    final newest = messages.last.data();
                    final createdAt = parseTimestamp(newest['createdAt']);
                    debugPrint(
                      'chat_thread_screen: message stream emitted, count '
                      '$_lastMessageCount->${messages.length}, newest '
                      'createdAt=$createdAt now=${DateTime.now()} '
                      'lagMs=${createdAt != null ? DateTime.now().difference(createdAt).inMilliseconds : "n/a"}',
                    );
                  }
                  _lastMessageCount = messages.length;
                  _scrollToBottom(animate: !isFirstLoad);
                }
                _syncReadStatus(messages, isAdminHere, myUnread);
                if (messages.isEmpty && !counterpartTyping) {
                  return _EmptyThreadView(
                    title: s.noMessagesYetTitle,
                    subtitle: s.typeMessageToStart,
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                  itemCount: messages.length + (counterpartTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      return const _TypingBubble();
                    }

                    final data = messages[index].data();
                    final createdAt = parseTimestamp(data['createdAt']);
                    final previousCreatedAt = index > 0
                        ? parseTimestamp(messages[index - 1].data()['createdAt'])
                        : null;
                    final showDateDivider = _isNewDay(
                      createdAt,
                      previousCreatedAt,
                    );
                    final isMine = data['senderId'] == myUid;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showDateDivider) _DateDivider(timestamp: createdAt),
                        _SwipeToReply(
                          isMine: isMine,
                          onReply: () => _startReply(messages[index]),
                          child: _MessageBubble(
                            text: data['text'] as String? ?? '',
                            sharedPostId: data['sharedPostId'] as String?,
                            sharedStoryId: data['sharedStoryId'] as String?,
                            sharedMediaUrl: data['mediaUrl'] as String?,
                            attachmentType: data['mediaType'] as String?,
                            repliedToStoryLabel: s.repliedToStory,
                            replyToText: data['replyToText'] as String?,
                            // Whoever's viewing this thread wrote the quoted
                            // message iff its role matches their own current
                            // role in this chat.
                            replyToSenderLabel:
                                data['replyToSenderRole'] == null
                                ? null
                                : (data['replyToSenderRole'] ==
                                          (isAdminHere ? 'admin' : 'user')
                                      ? s.you
                                      : title),
                            isMine: isMine,
                            timestamp: createdAt,
                            deliveredAt: parseTimestamp(data['deliveredAt']),
                            readAt: parseTimestamp(data['readAt']),
                            // Instagram shows "Seen HH:MM" once, under the
                            // newest message, not repeated on every bubble.
                            showSeenCaption: index == messages.length - 1,
                            seenLabel: s.seenAt,
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) =>
                  Center(child: Text('${s.failedToLoad}: $error')),
            ),
          ),
          if (isAdminHere) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _AcceptOrderChip(
                  label: s.acceptOrder,
                  onTap: () => showAcceptOrderSheet(
                    context,
                    chatId: widget.chatId,
                    userId: chat['userId'] as String,
                  ),
                ),
              ),
            ),
            _QuickRepliesRow(
              storeId: chat['storeId'] as String,
              onPick: (text) {
                _controller.text = text;
                _controller.selection = TextSelection.collapsed(
                  offset: text.length,
                );
              },
            ),
          ],
          SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.backgroundCard,
                border: Border(top: BorderSide(color: AppColors.borderDivider)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyingTo != null)
                    _ReplyPreviewBar(
                      senderLabel:
                          _replyingTo!['senderRole'] ==
                              (isAdminHere ? 'admin' : 'user')
                          ? s.you
                          : title,
                      text: _replyingTo!['text'] ?? '',
                      onCancel: () => setState(() => _replyingTo = null),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: _Composer(
                      controller: _controller,
                      hasText: _hasText,
                      hint: s.typeMessage,
                      onSend: _send,
                      onAttach: _attachMedia,
                      isAttaching: _isAttaching,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isNewDay(DateTime? current, DateTime? previous) {
    if (current == null) return false;
    if (previous == null) return true;
    return current.year != previous.year ||
        current.month != previous.month ||
        current.day != previous.day;
  }
}

/// Figma "No conversation yet" empty state — mailbox illustration, title,
/// subtitle. Shown only when this specific thread has zero messages (not
/// the chat *list* being empty, which is chat_list_screen.dart's own
/// noConversationsYet state).
class _EmptyThreadView extends StatelessWidget {
  const _EmptyThreadView({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/illustrations/no_message.svg',
              width: 140,
              colorFilter: ColorFilter.mode(
                AppColors.textMuted,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: AppTypography.bodyMediumSemibold,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Store's canned responses as one-tap chips above the composer (Settings ->
/// Quick Replies manages the list).
class _QuickRepliesRow extends ConsumerWidget {
  const _QuickRepliesRow({required this.storeId, required this.onPick});

  final String storeId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<JsonDoc>>(
      stream: ref.watch(quickRepliesServiceProvider).watch(storeId),
      builder: (context, snapshot) {
        final docs = snapshot.data ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            itemCount: docs.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final text = docs[index].data()['text'] as String? ?? '';
              return ActionChip(
                // ActionChip sizes itself to its label's natural width, so
                // maxLines/overflow alone never truncates a long reply — it
                // just grows the chip. Constraining the label is what
                // actually makes the ellipsis kick in.
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                labelStyle: AppTypography.bodySmall,
                backgroundColor: AppColors.backgroundCard,
                side: BorderSide(color: AppColors.borderDivider),
                onPressed: () => onPick(text),
              );
            },
          ),
        );
      },
    );
  }
}

/// Preview strip above the composer showing which message a long-press
/// picked to reply to — mirrors the quoted block _MessageBubble itself
/// renders once the reply is actually sent, minus the sender label (redundant
/// with the "Reply to X" heading here).
class _ReplyPreviewBar extends ConsumerWidget {
  const _ReplyPreviewBar({
    required this.senderLabel,
    required this.text,
    required this.onCancel,
  });

  final String senderLabel;
  final String text;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Container(width: 3, height: 32, color: AppColors.brand),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${s.reply} $senderLabel',
                  style: AppTypography.caption.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.brand,
                  ),
                ),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: AppIcon('close', size: 18, color: AppColors.textMuted),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Incoming "typing…" bubble: three dots pulsing in a staggered wave.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.backgroundCard,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Opacity(
                  // Triangle wave per dot, staggered by a third of a cycle.
                  opacity:
                      0.25 +
                      0.75 *
                          (1 -
                              (((_controller.value + i / 3) % 1.0) * 2 - 1)
                                  .abs()),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.textSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DateDivider extends ConsumerWidget {
  const _DateDivider({required this.timestamp});

  final DateTime? timestamp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          _label(ref.watch(l10nProvider), timestamp),
          style: AppTypography.label,
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

  static String _label(S s, DateTime? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(date.year, date.month, date.day);
    final formatted = '${date.day} ${_months[date.month - 1]}';
    if (day == today) return '${s.today}, $formatted';
    if (day == yesterday) return '${s.yesterday}, $formatted';
    return formatted;
  }
}

/// Instagram/WhatsApp-style swipe-to-reply: drag a bubble past
/// [_replyThreshold] and release to reply to it, instead of a long-press.
/// Direction is fixed per bubble (matches Telegram, not WhatsApp's
/// always-swipe-right): mine (right-aligned) swipes left, theirs
/// (left-aligned) swipes right — i.e. always toward the center, away from
/// whichever edge the bubble is anchored to. The bubble follows the finger
/// (clamped to [_maxDrag]) with a reply icon fading in behind it on the
/// trailing edge, then springs back once the drag ends.
///
/// Forces a tight full-width constraint onto the bubble via SizedBox (not
/// Stack's own `alignment`, and not Positioned.fill either) — [child] is
/// `_MessageBubble`, which positions itself left/right via its *own*
/// internal Column(crossAxisAlignment: isMine ? end : start), and that only
/// works when its parent hands it a tight full width, same as it gets one
/// layer up from the stretched item Column. Two things that would each
/// break it: letting Stack's own `alignment` float the whole (shrink-
/// wrapped) bubble instead (the first version of this widget — collapsed
/// every bubble, mine or theirs, onto the same side), or Positioned.fill
/// (forces the *height* to match the stack's, which — since the small reply
/// icon is the only other, non-positioned child informing that height —
/// would clip any bubble taller than the icon). SizedBox(width: infinity)
/// only ever constrains width, leaving height to size off the bubble's own
/// content like before.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.child,
    required this.isMine,
    required this.onReply,
  });

  final Widget child;
  final bool isMine;
  final VoidCallback onReply;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const _maxDrag = 64.0;
  static const _replyThreshold = 48.0;

  late final AnimationController _snapBack =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(() {
        setState(() => _dragExtent = _snapBackTween.evaluate(_snapBack));
      });
  Tween<double> _snapBackTween = Tween<double>(begin: 0, end: 0);
  double _dragExtent = 0;

  @override
  void dispose() {
    _snapBack.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      final next = _dragExtent + details.delta.dx;
      // Mine only ever goes negative (left), theirs only ever positive
      // (right) — clamping the *other* direction to 0 means a stray drag
      // the wrong way just does nothing instead of dragging backwards.
      _dragExtent = widget.isMine
          ? next.clamp(-_maxDrag, 0.0)
          : next.clamp(0.0, _maxDrag);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dragExtent.abs() >= _replyThreshold) widget.onReply();
    _snapBackTween = Tween<double>(begin: _dragExtent, end: 0);
    _snapBack
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragExtent.abs() / _replyThreshold).clamp(0.0, 1.0);
    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: widget.isMine ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          Opacity(
            opacity: progress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: AppIcon('send', size: 18, color: AppColors.textMuted),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: Transform.translate(
              offset: Offset(_dragExtent, 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.text,
    this.sharedPostId,
    this.sharedStoryId,
    this.sharedMediaUrl,
    this.attachmentType,
    required this.repliedToStoryLabel,
    this.replyToText,
    this.replyToSenderLabel,
    required this.isMine,
    required this.timestamp,
    required this.deliveredAt,
    required this.readAt,
    required this.showSeenCaption,
    required this.seenLabel,
  });

  final String text;
  final String? sharedPostId;
  final String? sharedStoryId;
  final String? sharedMediaUrl;
  // Denormalized quote of whichever message this one replies to (see
  // ChatService.sendMessage) — null on a message that isn't a reply.
  final String? replyToText;
  final String? replyToSenderLabel;

  /// "image" | "video" — set only for a raw gallery attachment (as opposed
  /// to a "send to chat" shared post/story, which use sharedPostId/
  /// sharedStoryId instead and carry their own preview rendering).
  final String? attachmentType;
  final String repliedToStoryLabel;
  final bool isMine;
  final DateTime? timestamp;

  /// Set by the *recipient's* client (see chat_service.dart's
  /// markMessagesDelivered/markMessagesRead) — null/null means only sent,
  /// deliveredAt-only means delivered-not-read, both set means read. Only
  /// meaningful (rendered) on my own messages — there's no status icon on
  /// an incoming bubble.
  final DateTime? deliveredAt;
  final DateTime? readAt;

  /// True only for the newest message in the thread — Instagram shows
  /// "Seen HH:MM" once under the last message, not repeated on every bubble.
  final bool showSeenCaption;
  final String Function(String time) seenLabel;

  @override
  Widget build(BuildContext context) {
    final isSharedPost = sharedPostId != null;
    final isStoryReply = sharedStoryId != null;
    final isAttachment =
        attachmentType != null && (sharedMediaUrl?.isNotEmpty ?? false);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (isStoryReply)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.reply, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    repliedToStoryLabel,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          GestureDetector(
            onTap: isSharedPost
                ? () => context.push('/post/$sharedPostId')
                : isAttachment
                ? () =>
                      _openAttachment(context, sharedMediaUrl!, attachmentType!)
                : null,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              padding: isSharedPost || isStoryReply || isAttachment
                  ? const EdgeInsets.all(6)
                  : const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isMine ? AppColors.brand : AppColors.backgroundCard,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMine ? 16 : 0),
                  bottomRight: Radius.circular(isMine ? 0 : 16),
                ),
              ),
              child: Column(
                // start, not stretch — a Container here has only a maxWidth
                // cap (no fixed width), so stretch would force every bubble
                // to render at the full cap regardless of how short its
                // content is, instead of hugging it like before this reply
                // quote block was added.
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (replyToText != null && replyToText!.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            width: 3,
                            color: isMine
                                ? AppColors.textOnPrimary.withValues(alpha: 0.6)
                                : AppColors.brand,
                          ),
                        ),
                        color: isMine
                            ? AppColors.textOnPrimary.withValues(alpha: 0.12)
                            : AppColors.backgroundPrimary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (replyToSenderLabel != null)
                            Text(
                              replyToSenderLabel!,
                              style: AppTypography.caption.copyWith(
                                fontWeight: FontWeight.w600,
                                color: isMine
                                    ? AppColors.textOnPrimary
                                    : AppColors.brand,
                              ),
                            ),
                          Text(
                            replyToText!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption.copyWith(
                              color: isMine
                                  ? AppColors.textOnPrimary.withValues(
                                      alpha: 0.85,
                                    )
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  isSharedPost
                      ? _SharedPostPreview(
                          postId: sharedPostId,
                          mediaUrl: sharedMediaUrl ?? '',
                          caption: text,
                          onLight: !isMine,
                        )
                      : isStoryReply && (sharedMediaUrl?.isNotEmpty ?? false)
                      ? _SharedPostPreview(
                          mediaUrl: sharedMediaUrl!,
                          caption: text,
                          onLight: !isMine,
                        )
                      : isAttachment
                      ? _AttachmentThumbnail(
                          mediaUrl: sharedMediaUrl!,
                          mediaType: attachmentType!,
                        )
                      : Text(
                          text,
                          style: AppTypography.bodyMedium.copyWith(
                            color: isMine
                                ? AppColors.textOnPrimary
                                : AppColors.textPrimary,
                          ),
                        ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isMine) ...[
                AppIcon(
                  // Single check = sent only; double gray = delivered to
                  // their device; double blue = they've opened the thread
                  // and read it. See chat_service.dart's
                  // markMessagesDelivered/markMessagesRead for who sets
                  // these and when.
                  readAt != null || deliveredAt != null
                      ? 'check_double'
                      : 'check',
                  size: 16,
                  color: readAt != null
                      ? AppColors.brand
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 2),
              ],
              Text(_formatTime(timestamp), style: AppTypography.caption),
            ],
          ),
          if (isMine && showSeenCaption && readAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                seenLabel(_formatTime(readAt)),
                style: AppTypography.caption.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime? timestamp) {
    if (timestamp == null) return '';
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// Inline preview for a "send to chat"-shared post or story reply —
/// thumbnail + caption, tap opens the full post (handled by the parent
/// bubble's GestureDetector).
class _SharedPostPreview extends ConsumerWidget {
  const _SharedPostPreview({
    this.postId,
    required this.mediaUrl,
    required this.caption,
    required this.onLight,
  });

  /// When set, the preview image is resolved live from the post doc — the
  /// URL stored on the message can be a raw video file for reels shared
  /// before the thumbnail fix, which no image decoder will ever accept.
  final String? postId;
  final String mediaUrl;
  final String caption;

  /// True when rendered on the light (incoming) bubble background, so text
  /// needs dark ink instead of the brand bubble's white-on-purple.
  final bool onLight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = onLight ? AppColors.textPrimary : AppColors.textOnPrimary;

    final post = postId != null
        ? ref.watch(postDocProvider(postId!)).value
        : null;
    final isReel = post?['type'] == 'reel';
    String imageUrl = mediaUrl;
    if (post != null) {
      final thumbnailUrl = post['thumbnailUrl'] as String? ?? '';
      final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? [])
          .cast<String>();
      imageUrl = isReel
          ? thumbnailUrl // may be empty (no thumbnail generated) — placeholder below
          : (mediaUrls.isNotEmpty ? mediaUrls.first : mediaUrl);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imageUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) =>
                        const _VideoPlaceholder(),
                  )
                else if (isReel)
                  const _VideoPlaceholder()
                else
                  Container(color: AppColors.borderDivider),
                // Reels read as videos, not broken images: play badge on top.
                if (isReel)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
            child: Text(
              caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodySmall.copyWith(color: textColor),
            ),
          ),
      ],
    );
  }
}

/// Dark tile shown when a reel has no renderable preview image.
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(color: const Color(0xFF3A3A3A));
  }
}

void _openAttachment(BuildContext context, String mediaUrl, String mediaType) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) =>
          _AttachmentViewerScreen(mediaUrl: mediaUrl, mediaType: mediaType),
    ),
  );
}

/// A gallery-picked photo/video attached directly to a message (as opposed
/// to a "send to chat" shared post/story, which get their own
/// _SharedPostPreview) — square thumbnail matching that same layout, tap
/// opens the full-size viewer below.
class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({required this.mediaUrl, required this.mediaType});

  final String mediaUrl;
  final String mediaType;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (mediaType == 'video')
              const _VideoPlaceholder()
            else
              CachedNetworkImage(
                imageUrl: mediaUrl,
                fit: BoxFit.cover,
                errorWidget: (context, url, error) => const _VideoPlaceholder(),
              ),
            if (mediaType == 'video')
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white,
                  size: 40,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentViewerScreen extends StatefulWidget {
  const _AttachmentViewerScreen({
    required this.mediaUrl,
    required this.mediaType,
  });

  final String mediaUrl;
  final String mediaType;

  @override
  State<_AttachmentViewerScreen> createState() =>
      _AttachmentViewerScreenState();
}

class _AttachmentViewerScreenState extends State<_AttachmentViewerScreen> {
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == 'video') {
      final vc = VideoPlayerController.networkUrl(Uri.parse(widget.mediaUrl));
      _video = vc;
      vc.initialize().then((_) {
        if (mounted) setState(() {});
        vc.play();
      });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: widget.mediaType == 'video'
                ? (video != null && video.value.isInitialized)
                      ? AspectRatio(
                          aspectRatio: video.value.aspectRatio,
                          child: GestureDetector(
                            onTap: () => setState(
                              () => video.value.isPlaying
                                  ? video.pause()
                                  : video.play(),
                            ),
                            child: VideoPlayer(video),
                          ),
                        )
                      : const CircularProgressIndicator(color: Colors.white)
                : InteractiveViewer(
                    child: CachedNetworkImage(
                      imageUrl: widget.mediaUrl,
                      fit: BoxFit.contain,
                    ),
                  ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const AppIcon('close', color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _AcceptOrderChip extends StatelessWidget {
  const _AcceptOrderChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.brand,
      borderRadius: BorderRadius.circular(500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(500),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.26,
              color: AppColors.textOnPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.hasText,
    required this.hint,
    required this.onSend,
    required this.onAttach,
    required this.isAttaching,
  });

  final TextEditingController controller;
  final bool hasText;
  final String hint;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final bool isAttaching;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.backgroundPrimary,
        borderRadius: BorderRadius.circular(500),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: isAttaching ? null : onAttach,
                    child: isAttaching
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.textMuted,
                              ),
                            ),
                          )
                        : AppIcon(
                            'image',
                            size: 24,
                            color: AppColors.textMuted,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      style: AppTypography.bodyMedium,
                      // Keyboard's Done key only dismisses the keyboard —
                      // it isn't a second send button. Sending is
                      // exclusively the explicit send icon on the right.
                      onSubmitted: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      decoration: InputDecoration(
                        hintText: hint,
                        hintStyle: AppTypography.bodyMedium.copyWith(
                          color: AppColors.textMuted,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Material(
            color: hasText ? AppColors.brand : AppColors.buttonMuted,
            borderRadius: BorderRadius.circular(500),
            child: InkWell(
              onTap: onSend,
              borderRadius: BorderRadius.circular(500),
              child: const SizedBox(
                width: 64,
                height: double.infinity,
                child: Icon(Icons.send_rounded, size: 24, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
