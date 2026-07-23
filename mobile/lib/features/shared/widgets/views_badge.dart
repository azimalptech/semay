import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// Bottom-right overlay badge on a post's media — used by PostCard (feed
/// tile, image/carousel posts only — reels keep their inline count, see
/// post_card.dart) and ImagePostDetailContent (detail view). Moved off the
/// shared icon row below the media, which was getting crowded: Figma
/// 195:4335's carousel page dots sit centered in that row and were visually
/// mixing with the eye icon+count, and on the owner's own posts the row's
/// right end is already busy with edit/delete. Mirrors the top-right "1/3"
/// carousel counter's blurred-pill styling for visual consistency.
class ViewsBadge extends StatelessWidget {
  const ViewsBadge({super.key, required this.viewsCount});

  final int viewsCount;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.overlayAlphaBlack,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.visibility_outlined,
                size: 14,
                color: AppColors.textOnPrimary,
              ),
              const SizedBox(width: 4),
              Text(
                '$viewsCount',
                style: AppTypography.bodySmall.copyWith(
                  color: AppColors.textOnPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
