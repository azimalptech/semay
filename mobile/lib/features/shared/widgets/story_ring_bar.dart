import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app_icon.dart';
import '../../../core/theme.dart';
import '../../story_composer/add_story_flow.dart';
import '../../story_viewer/story_viewer_screen.dart' show StoryViewerArgs;
import '../story_bar_provider.dart';

/// Homepage story bar — Figma frame 195:4299 node 195:4308 (user) and
/// 223:4769 (admin, with the "+" add-story badge on the own-store ring).
/// Unseen rings draw the brand sweep gradient with a slow Instagram-style
/// rotation; watched-to-the-end rings fall back to the muted border.
class StoryRingBar extends ConsumerStatefulWidget {
  const StoryRingBar({super.key, required this.storyRoutePrefix});

  /// `/home/story` for User mode, `/admin/home/story` for Admin mode.
  final String storyRoutePrefix;

  @override
  ConsumerState<StoryRingBar> createState() => _StoryRingBarState();
}

class _StoryRingBarState extends ConsumerState<StoryRingBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rings = ref.watch(storyBarProvider).value ?? [];
    if (rings.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: SizedBox(
        height: 116,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          // Each _StoryRing is shifted up 15px via Transform.translate below
          // (paint-only — its layout box doesn't grow to match), which the
          // viewport's default Clip.hardEdge then slices off since it now
          // paints above y=0. Clip.none lets that shifted paint through
          // instead of cutting the top off every ring.
          clipBehavior: Clip.none,
          itemCount: rings.length,
          separatorBuilder: (context, index) => const SizedBox(width: 16),
          itemBuilder: (context, index) {
            final ring = rings[index];
            return _StoryRing(
              ring: ring,
              spin: _spin,
              onTap: () {
                if (ring.hasStories) {
                  // The full ordered queue (not just the tapped ring) so the
                  // viewer can swipe horizontally between users, Instagram-
                  // style, instead of only showing whichever one was tapped.
                  final queue = [
                    for (final r in rings)
                      if (r.hasStories) r.storeId,
                  ];
                  context.push(
                    '${widget.storyRoutePrefix}/${ring.storeId}',
                    extra: StoryViewerArgs(
                      storeIds: queue,
                      initialIndex: queue.indexOf(ring.storeId),
                    ),
                  );
                } else if (ring.isOwn) {
                  showAddStorySheet(context, ref, storeId: ring.storeId);
                }
              },
              onAdd: ring.isOwn
                  ? () => showAddStorySheet(context, ref, storeId: ring.storeId)
                  : null,
            );
          },
        ),
      ),
    );
  }
}

class _StoryRing extends StatelessWidget {
  const _StoryRing({
    required this.ring,
    required this.spin,
    required this.onTap,
    this.onAdd,
  });

  final StoryRingInfo ring;
  final Animation<double> spin;
  final VoidCallback onTap;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Transform.translate(
        offset: const Offset(0, -15),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 90,
              height: 90,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: spin,
                      builder: (context, child) => CustomPaint(
                        painter: _RingPainter(
                          rotation: ring.hasStories && !ring.seen
                              ? spin.value * 2 * math.pi
                              : 0,
                          gradient: ring.hasStories && !ring.seen,
                          color: ring.hasStories
                              ? AppColors.buttonMuted
                              : Colors.transparent,
                        ),
                        child: child,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: CircleAvatar(
                          backgroundColor: AppColors.backgroundCard,
                          backgroundImage: ring.avatarUrl.isNotEmpty
                              ? CachedNetworkImageProvider(ring.avatarUrl)
                              : null,
                          child: ring.avatarUrl.isEmpty
                              ? Icon(
                                  Icons.storefront,
                                  color: AppColors.textMuted,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                  if (onAdd != null)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: GestureDetector(
                        onTap: onAdd,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: AppColors.brand,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.backgroundPrimary,
                              width: 1.5,
                            ),
                          ),
                          child: const AppIcon(
                            'plus',
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 76,
              child: Text(
                ring.storeName,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.rotation,
    required this.gradient,
    required this.color,
  });

  final double rotation;
  final bool gradient;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    if (gradient) {
      paint.shader = SweepGradient(
        colors: AppColors.storyGradient,
        transform: GradientRotation(rotation),
      ).createShader(rect);
    } else {
      if (color == Colors.transparent) return;
      paint.color = color;
    }

    canvas.drawCircle(rect.center, (size.width - paint.strokeWidth) / 2, paint);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.gradient != gradient ||
      oldDelegate.color != color;
}
