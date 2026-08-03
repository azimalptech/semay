import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/l10n.dart';
import '../../services/chat_service.dart';
import 'chat_providers.dart';

Future<void> showAcceptOrderSheet(
  BuildContext context, {
  required String chatId,
  required String userId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => AcceptOrderSheet(chatId: chatId, userId: userId),
  );
}

class AcceptOrderSheet extends ConsumerStatefulWidget {
  const AcceptOrderSheet({
    super.key,
    required this.chatId,
    required this.userId,
  });

  final String chatId;
  final String userId;

  @override
  ConsumerState<AcceptOrderSheet> createState() => _AcceptOrderSheetState();
}

class _AcceptOrderSheetState extends ConsumerState<AcceptOrderSheet> {
  int _quantity = 1;
  bool _submitting = false;

  // One key per opened sheet, deliberately NOT regenerated per tap. Accepting
  // an order records a sale and moves the prize leaderboard, so a send that
  // succeeded server-side but lost its response (flaky signal) must not become
  // a second sale when the admin retries — the server dedupes on this key.
  // Reopening the sheet mints a new one, so a genuinely intended second order
  // still goes through.
  final String _clientKey = const Uuid().v4();

  Future<void> _submit(String userPhone) async {
    setState(() => _submitting = true);
    try {
      await ref
          .read(chatServiceProvider)
          .acceptOrder(
            chatId: widget.chatId,
            itemQuantity: _quantity,
            userPhone: userPhone,
            clientKey: _clientKey,
          );
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ref.read(l10nProvider).orderAccepted)),
        );
      }
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final customer = ref.watch(userDocProvider(widget.userId)).value;
    final userPhone = customer?['phone'] as String?;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.acceptOrder, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(s.quantity),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: _quantity > 1
                    ? () => setState(() => _quantity--)
                    : null,
              ),
              Text('$_quantity'),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => setState(() => _quantity++),
              ),
            ],
          ),
          Row(
            children: [
              Text(s.phoneLabel),
              const Spacer(),
              Text(
                userPhone ?? '...',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: (_submitting || userPhone == null)
                ? null
                : () => _submit(userPhone),
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(),
                  )
                : Text(s.acceptOrder),
          ),
        ],
      ),
    );
  }
}
