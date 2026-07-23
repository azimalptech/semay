import 'package:flutter/material.dart';

/// Instagram-style double-tap-to-like: wraps any post/reel media so a
/// double tap likes it (never unlikes — a second double-tap is a no-op,
/// same as the real app) and pops a big heart that scales up and fades out.
/// A single tap still passes through to [onSingleTap] if given.
class DoubleTapLikeOverlay extends StatefulWidget {
  const DoubleTapLikeOverlay({
    super.key,
    required this.child,
    required this.isLiked,
    required this.onLike,
    this.onSingleTap,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final Widget child;
  final bool isLiked;
  final VoidCallback onLike;
  final VoidCallback? onSingleTap;

  /// Press-and-hold, release to end — optional, only reels/stories wire
  /// these up. onHoldStart receives where the press landed so a caller that
  /// cares which zone was held (e.g. reels: center vs. edges) can tell.
  final void Function(LongPressStartDetails)? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  State<DoubleTapLikeOverlay> createState() => _DoubleTapLikeOverlayState();
}

class _DoubleTapLikeOverlayState extends State<DoubleTapLikeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.15), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 20),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 25),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 5),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 70),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 25),
  ]).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (!widget.isLiked) widget.onLike();
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSingleTap,
      onDoubleTap: _handleDoubleTap,
      onLongPressStart: widget.onHoldStart,
      onLongPressEnd: widget.onHoldEnd != null
          ? (_) => widget.onHoldEnd!()
          : null,
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.passthrough,
        children: [
          widget.child,
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => Opacity(
                opacity: _opacity.value,
                child: Transform.scale(
                  scale: _scale.value,
                  child: const Icon(
                    Icons.favorite,
                    color: Colors.white,
                    size: 100,
                    shadows: [Shadow(color: Colors.black38, blurRadius: 12)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
