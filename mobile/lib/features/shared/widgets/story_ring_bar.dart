import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../story_bar_provider.dart';

class StoryRingBar extends ConsumerWidget {
  const StoryRingBar({super.key, required this.storyRoutePrefix});

  /// `/home/story` for User mode, `/admin/home/story` for Admin mode.
  final String storyRoutePrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rings = ref.watch(storyBarProvider).value ?? [];
    if (rings.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: rings.length,
        itemBuilder: (context, index) {
          final ring = rings[index];
          return GestureDetector(
            onTap: () => context.push('$storyRoutePrefix/${ring.storeId}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 30,
                      backgroundImage:
                          ring.avatarUrl.isNotEmpty ? CachedNetworkImageProvider(ring.avatarUrl) : null,
                      child: ring.avatarUrl.isEmpty ? const Icon(Icons.storefront) : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 64,
                    child: Text(
                      ring.storeName,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
