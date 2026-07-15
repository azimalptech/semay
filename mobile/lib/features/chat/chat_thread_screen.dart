import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../store_profile/store_profile_providers.dart';
import 'accept_order_sheet.dart';
import 'chat_providers.dart';

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

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _markReadOnce(bool isAdmin) {
    if (_markedRead) return;
    _markedRead = true;
    ref.read(chatServiceProvider).markThreadRead(widget.chatId, asAdmin: isAdmin);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatDocProvider(widget.chatId)).value;
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isAdminHere = (role == AppRole.admin || role == AppRole.superadmin) &&
        chat != null &&
        storeIds.contains(chat['storeId']);

    if (chat != null) _markReadOnce(isAdminHere);

    final store = chat != null ? ref.watch(storeDocProvider(chat['storeId'] as String)).value : null;
    final customer = chat != null ? ref.watch(userDocProvider(chat['userId'] as String)).value : null;
    final title = isAdminHere ? (customer?['name'] as String? ?? '...') : (store?['name'] as String? ?? '...');

    final messagesAsync = ref.watch(chatMessagesProvider(widget.chatId));

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Icon(Icons.call_outlined, color: AppColors.textPrimary),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) => ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                itemCount: messages.length,
                itemBuilder: (context, index) {
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
                        isMine: isMine,
                        timestamp: createdAt,
                      ),
                    ],
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(child: Text('Error: $error')),
            ),
          ),
          if (isAdminHere)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _AcceptOrderChip(
                  onTap: () => showAcceptOrderSheet(
                    context,
                    chatId: widget.chatId,
                    userId: chat['userId'] as String,
                  ),
                ),
              ),
            ),
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
                onSend: () {
                  final text = _controller.text.trim();
                  if (text.isEmpty) return;
                  ref.read(chatServiceProvider).sendMessage(
                        widget.chatId,
                        text,
                        senderRole: isAdminHere ? 'admin' : 'user',
                      );
                  _controller.clear();
                },
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

class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.timestamp});

  final Timestamp? timestamp;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(child: Text(_label(timestamp), style: AppTypography.label)),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _label(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(date.year, date.month, date.day);
    final formatted = '${date.day} ${_months[date.month - 1]}';
    if (day == today) return 'Today, $formatted';
    if (day == yesterday) return 'Yesterday, $formatted';
    return formatted;
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.text, required this.isMine, required this.timestamp});

  final String text;
  final bool isMine;
  final Timestamp? timestamp;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isMine ? AppColors.brand : AppColors.backgroundCard,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMine ? 16 : 0),
                bottomRight: Radius.circular(isMine ? 0 : 16),
              ),
            ),
            child: Text(
              text,
              style: AppTypography.bodyMedium.copyWith(
                color: isMine ? AppColors.textOnPrimary : AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isMine) ...[
                const Icon(Icons.done, size: 16, color: AppColors.textSecondary),
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

class _AcceptOrderChip extends StatelessWidget {
  const _AcceptOrderChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.brand,
      borderRadius: BorderRadius.circular(500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(500),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            'kabul edildi',
            style: TextStyle(
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
  const _Composer({required this.controller, required this.hasText, required this.onSend});

  final TextEditingController controller;
  final bool hasText;
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
                      decoration: InputDecoration(
                        hintText: 'Type message',
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
