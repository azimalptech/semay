import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

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

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  final _controller = TextEditingController();
  bool _markedRead = false;
  bool _hasText = false;
  bool _isAdminHere = false;
  DateTime _lastTypingWrite = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _staleness;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // Re-evaluates typing-indicator freshness so it disappears when the other
    // side goes quiet without another snapshot arriving.
    _staleness = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);

    if (hasText && DateTime.now().difference(_lastTypingWrite) > _typingWriteGap) {
      _lastTypingWrite = DateTime.now();
      ref
          .read(chatServiceProvider)
          .setTyping(widget.chatId, asAdmin: _isAdminHere, isTyping: true);
    }
  }

  @override
  void dispose() {
    _staleness?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _markReadOnce(bool isAdmin) {
    if (_markedRead) return;
    _markedRead = true;
    ref.read(chatServiceProvider).markThreadRead(widget.chatId, asAdmin: isAdmin);
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final service = ref.read(chatServiceProvider);
    service.sendMessage(widget.chatId, text, senderRole: _isAdminHere ? 'admin' : 'user');
    service.setTyping(widget.chatId, asAdmin: _isAdminHere, isTyping: false);
    _lastTypingWrite = DateTime.fromMillisecondsSinceEpoch(0);
    _controller.clear();
  }

  static bool _isFresh(Timestamp? at) =>
      at != null && DateTime.now().difference(at.toDate()) < _typingFreshness;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final chat = ref.watch(chatDocProvider(widget.chatId)).value;
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isAdminHere = (role == AppRole.admin || role == AppRole.superadmin) &&
        chat != null &&
        storeIds.contains(chat['storeId']);
    _isAdminHere = isAdminHere;

    if (chat != null) _markReadOnce(isAdminHere);

    final store = chat != null ? ref.watch(storeDocProvider(chat['storeId'] as String)).value : null;
    final customer = chat != null ? ref.watch(userDocProvider(chat['userId'] as String)).value : null;
    final title = isAdminHere ? (customer?['name'] as String? ?? '…') : (store?['name'] as String? ?? '…');

    // Counterpart state, derived from the chat doc: their typing heartbeat,
    // and whether they've read everything I sent (their unread == 0).
    final counterpartTyping =
        _isFresh(chat?[isAdminHere ? 'typingUserAt' : 'typingAdminAt'] as Timestamp?);
    final counterpartRead = (chat?[isAdminHere ? 'unreadByUser' : 'unreadByAdmin'] as int? ?? 0) == 0;

    final messagesAsync = ref.watch(chatMessagesProvider(widget.chatId));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            if (counterpartTyping)
              Text(s.typing,
                  style: AppTypography.caption.copyWith(color: AppColors.brand)),
          ],
        ),
        actions: [
          Builder(builder: (context) {
            final counterpartData = isAdminHere ? customer : store;
            final counterpartPhone = counterpartData?['phone'] as String?;
            return IconButton(
              icon: const Icon(Icons.call_outlined, color: AppColors.textPrimary),
              onPressed: (counterpartPhone == null || counterpartPhone.isEmpty)
                  ? null
                  : () async {
                      final uri = Uri(scheme: 'tel', path: counterpartPhone);
                      if (!await launchUrl(uri) && context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(s.couldNotOpenDialer)));
                      }
                    },
            );
          }),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) => ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                itemCount: messages.length + (counterpartTyping ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == messages.length) return const _TypingBubble();

                  final data = messages[index].data();
                  final createdAt = data['createdAt'] as Timestamp?;
                  final previousCreatedAt =
                      index > 0 ? messages[index - 1].data()['createdAt'] as Timestamp? : null;
                  final showDateDivider = _isNewDay(createdAt, previousCreatedAt);
                  final isMine = data['senderId'] == myUid;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showDateDivider) _DateDivider(timestamp: createdAt),
                      _MessageBubble(
                        text: data['text'] as String? ?? '',
                        sharedPostId: data['sharedPostId'] as String?,
                        sharedStoryId: data['sharedStoryId'] as String?,
                        sharedMediaUrl: data['mediaUrl'] as String?,
                        repliedToStoryLabel: s.repliedToStory,
                        isMine: isMine,
                        timestamp: createdAt,
                        seen: isMine && counterpartRead,
                      ),
                    ],
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(child: Text('${s.failedToLoad}: $error')),
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
                _controller.selection = TextSelection.collapsed(offset: text.length);
              },
            ),
          ],
          SafeArea(
            top: false,
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.backgroundCard,
                border: Border(top: BorderSide(color: AppColors.borderDivider)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 17, 16, 16),
              child: _Composer(
                controller: _controller,
                hasText: _hasText,
                hint: s.typeMessage,
                onSend: _send,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isNewDay(Timestamp? current, Timestamp? previous) {
    if (current == null) return false;
    if (previous == null) return true;
    final a = current.toDate();
    final b = previous.toDate();
    return a.year != b.year || a.month != b.month || a.day != b.day;
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
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
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
                  child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                labelStyle: AppTypography.bodySmall,
                backgroundColor: AppColors.backgroundCard,
                side: const BorderSide(color: AppColors.borderDivider),
                onPressed: () => onPick(text),
              );
            },
          ),
        );
      },
    );
  }
}

/// Incoming "typing…" bubble: three dots pulsing in a staggered wave.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

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
        decoration: const BoxDecoration(
          color: AppColors.backgroundCard,
          borderRadius: BorderRadius.only(
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
                  opacity: 0.25 +
                      0.75 * (1 - (((_controller.value + i / 3) % 1.0) * 2 - 1).abs()),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
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

  final Timestamp? timestamp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(child: Text(_label(ref.watch(l10nProvider), timestamp), style: AppTypography.label)),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _label(S s, Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.text,
    this.sharedPostId,
    this.sharedStoryId,
    this.sharedMediaUrl,
    required this.repliedToStoryLabel,
    required this.isMine,
    required this.timestamp,
    required this.seen,
  });

  final String text;
  final String? sharedPostId;
  final String? sharedStoryId;
  final String? sharedMediaUrl;
  final String repliedToStoryLabel;
  final bool isMine;
  final Timestamp? timestamp;
  final bool seen;

  @override
  Widget build(BuildContext context) {
    final isSharedPost = sharedPostId != null;
    final isStoryReply = sharedStoryId != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isStoryReply)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.reply, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text(repliedToStoryLabel,
                      style: AppTypography.caption.copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          GestureDetector(
            onTap: isSharedPost ? () => context.push('/post/$sharedPostId') : null,
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              padding: isSharedPost || isStoryReply
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
              child: isSharedPost
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
                      : Text(
                          text,
                          style: AppTypography.bodyMedium.copyWith(
                            color: isMine ? AppColors.textOnPrimary : AppColors.textPrimary,
                          ),
                        ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isMine) ...[
                Icon(
                  seen ? Icons.done_all : Icons.done,
                  size: 16,
                  color: seen ? AppColors.brand : AppColors.textSecondary,
                ),
                const SizedBox(width: 2),
              ],
              Text(_formatTime(timestamp), style: AppTypography.caption),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
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

    final post = postId != null ? ref.watch(postDocProvider(postId!)).value : null;
    final isReel = post?['type'] == 'reel';
    String imageUrl = mediaUrl;
    if (post != null) {
      final thumbnailUrl = post['thumbnailUrl'] as String? ?? '';
      final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? []).cast<String>();
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
                    errorWidget: (context, url, error) => const _VideoPlaceholder(),
                  )
                else if (isReel)
                  const _VideoPlaceholder()
                else
                  Container(color: AppColors.borderDivider),
                // Reels read as videos, not broken images: play badge on top.
                if (isReel)
                  const Center(
                    child: Icon(Icons.play_circle_fill, color: Colors.white, size: 40),
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
  });

  final TextEditingController controller;
  final bool hasText;
  final String hint;
  final VoidCallback onSend;

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
                  const Icon(Icons.image_outlined, size: 24, color: AppColors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      style: AppTypography.bodyMedium,
                      onSubmitted: (_) => onSend(),
                      decoration: InputDecoration(
                        hintText: hint,
                        hintStyle: AppTypography.bodyMedium.copyWith(color: AppColors.textMuted),
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
