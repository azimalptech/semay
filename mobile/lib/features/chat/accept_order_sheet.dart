import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/chat_service.dart';
import '../store_profile/store_profile_providers.dart';
import 'chat_providers.dart';

Future<void> showAcceptOrderSheet(
  BuildContext context, {
  required String chatId,
  required String storeId,
  required String userId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => AcceptOrderSheet(chatId: chatId, storeId: storeId, userId: userId),
  );
}

class AcceptOrderSheet extends ConsumerStatefulWidget {
  const AcceptOrderSheet({
    super.key,
    required this.chatId,
    required this.storeId,
    required this.userId,
  });

  final String chatId;
  final String storeId;
  final String userId;

  @override
  ConsumerState<AcceptOrderSheet> createState() => _AcceptOrderSheetState();
}

class _AcceptOrderSheetState extends ConsumerState<AcceptOrderSheet> {
  String? _selectedPostId;
  int _quantity = 1;
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _submitting = false;
  bool _phonePrefilled = false;

  @override
  void dispose() {
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selectedPostId == null) {
      _showError('Pick which post is being discussed');
      return;
    }
    if (_addressController.text.trim().isEmpty) {
      _showError('Delivery address is required');
      return;
    }
    if (_phoneController.text.trim().isEmpty) {
      _showError('Phone number is required');
      return;
    }

    setState(() => _submitting = true);
    try {
      await ref.read(chatServiceProvider).acceptOrder(
            chatId: widget.chatId,
            postId: _selectedPostId!,
            itemQuantity: _quantity,
            deliveryAddress: _addressController.text.trim(),
            userPhone: _phoneController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Order accepted')));
      }
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final postsAsync = ref.watch(storePostsProvider(widget.storeId));
    final customer = ref.watch(userDocProvider(widget.userId)).value;
    if (!_phonePrefilled && customer?['phone'] != null) {
      _phoneController.text = customer!['phone'] as String;
      _phonePrefilled = true;
    }

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
          Text('Accept order', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          postsAsync.when(
            data: (posts) => DropdownButtonFormField<String>(
              initialValue: _selectedPostId,
              decoration: const InputDecoration(labelText: 'Item (post)'),
              items: [
                for (final doc in posts)
                  DropdownMenuItem(
                    value: doc.id,
                    child: Text(
                      (doc.data()['caption'] as String?)?.isNotEmpty == true
                          ? doc.data()['caption'] as String
                          : doc.id,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _selectedPostId = value),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (error, stack) => Text('Error loading posts: $error'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Quantity'),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: _quantity > 1 ? () => setState(() => _quantity--) : null,
              ),
              Text('$_quantity'),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => setState(() => _quantity++),
              ),
            ],
          ),
          TextField(
            controller: _addressController,
            decoration: const InputDecoration(labelText: 'Delivery address'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _phoneController,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator())
                : const Text('kabul edildi'),
          ),
        ],
      ),
    );
  }
}
