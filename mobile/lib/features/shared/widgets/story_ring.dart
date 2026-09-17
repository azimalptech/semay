import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// The story ring stroke, shared by the home story bar and the store
/// profile header so both draw the same state the same way. The one rule:
/// active AND unseen → brand sweep gradient; active AND seen → muted border;
/// no active story → nothing (the caller keeps its padding so layout does
/// not jump when a ring appears or expires).
class StoryRingPainter extends CustomPainter {
  StoryRingPainter({
    required bool hasStories,
    required bool seen,
    this.rotation = 0,
  }) : gradient = hasStories && !seen,
       color = hasStories ? AppColors.buttonMuted : Colors.transparent;

  /// Sweep-gradient start angle in radians — the bar spins it slowly
  /// (Instagram-style); a static caller leaves it at 0.
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
  bool shouldRepaint(StoryRingPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.gradient != gradient ||
      oldDelegate.color != color;
}
