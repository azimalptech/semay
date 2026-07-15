import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) => ListView.builder(
                reverse: false,
                padding: const EdgeInsets.all(8),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final data = messages[index].data();
                  if (data['orderId'] != null) {
                    return _SystemMessageChip(text: data['text'] as String? ?? '');
                  }
                  final isMine = data['senderId'] == myUid;
                  return _MessageBubble(text: data['text'] as String? ?? '', isMine: isMine);
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(child: Text('Error: $error')),
            ),
          ),
          if (isAdminHere)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => showAcceptOrderSheet(
                    context,
                    chatId: widget.chatId,
                    storeId: chat['storeId'] as String,
                    userId: chat['userId'] as String,
                  ),
                  child: const Text('kabul edildi'),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(hintText: 'Message...'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () {
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.text, required this.isMine});

  final String text;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMine ? colorScheme.primary : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text, style: TextStyle(color: isMine ? colorScheme.onPrimary : null)),
      ),
    );
  }
}

class _SystemMessageChip extends StatelessWidget {
  const _SystemMessageChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}
