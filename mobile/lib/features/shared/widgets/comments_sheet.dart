import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/auth_service.dart';
import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';

Future<void> showCommentsSheet(
  BuildContext context, {
  required String postId,
  required String postStoreId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => CommentsSheet(postId: postId, postStoreId: postStoreId),
  );
}

class CommentsSheet extends ConsumerStatefulWidget {
  const CommentsSheet({super.key, required this.postId, required this.postStoreId});

  final String postId;
  final String postStoreId;

  @override
  ConsumerState<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<CommentsSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final comments = ref.watch(commentsProvider(widget.postId)).value ?? [];
    final myUid = ref.watch(firebaseAuthProvider).currentUser?.uid;
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isStoreAdminHere =
        (role == AppRole.admin || role == AppRole.superadmin) && storeIds.contains(widget.postStoreId);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          const Padding(padding: EdgeInsets.all(12), child: Text('Comments')),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: comments.length,
              itemBuilder: (context, index) {
                final doc = comments[index];
                final data = doc.data();
                final canDelete = data['uid'] == myUid || isStoreAdminHere;
                return ListTile(
                  title: Text(data['userName'] as String? ?? ''),
                  subtitle: Text(data['text'] as String? ?? ''),
                  trailing: canDelete
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () =>
                              ref.read(postsServiceProvider).deleteComment(widget.postId, doc.id),
                        )
                      : null,
                );
              },
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
                      decoration: const InputDecoration(hintText: 'Add a comment...'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () {
                      final text = _controller.text.trim();
                      if (text.isEmpty) return;
                      ref.read(postsServiceProvider).addComment(widget.postId, text);
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
