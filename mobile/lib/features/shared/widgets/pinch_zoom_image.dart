import 'package:flutter/material.dart';

/// Instagram-style pinch-to-zoom on a post image: pinch/pan while your
/// fingers are down, elastic snap back to the grid the moment you lift them
/// — this is a transient magnifier, not a persistent zoomed state.
///
/// Built on InteractiveViewer (scale + pan) rather than a hand-rolled
/// GestureDetector so it composes safely with the carousel PageView this
/// usually sits inside: `panEnabled` only turns on once actually zoomed in,
/// so an at-rest single-finger drag is left for the PageView's own swipe
/// recognizer instead of being captured here. Rotation is intentionally not
/// implemented — InteractiveViewer doesn't expose two-finger rotation, and
/// hand-rolling it risks exactly the swipe-gesture conflict this design
/// avoids.
class PinchZoomImage extends StatefulWidget {
  const PinchZoomImage({super.key, required this.child});

  final Widget child;

  @override
  State<PinchZoomImage> createState() => _PinchZoomImageState();
}

class _PinchZoomImageState extends State<PinchZoomImage> with SingleTickerProviderStateMixin {
  final _transformationController = TransformationController();
  late final AnimationController _resetController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  )..addListener(() {
      if (_resetAnimation != null) {
        _transformationController.value = _resetAnimation!.value;
      }
    });
  Animation<Matrix4>? _resetAnimation;
  bool _zoomed = false;

  @override
  void dispose() {
    _resetController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _onInteractionStart(ScaleStartDetails details) {
    _resetController.stop();
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    final isZoomed = scale > 1.01;
    if (isZoomed != _zoomed) setState(() => _zoomed = isZoomed);
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    _resetAnimation = Matrix4Tween(
      begin: _transformationController.value,
      end: Matrix4.identity(),
    ).animate(CurvedAnimation(parent: _resetController, curve: Curves.elasticOut));
    _resetController.forward(from: 0);
    setState(() => _zoomed = false);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: InteractiveViewer(
        transformationController: _transformationController,
        minScale: 1.0,
        maxScale: 4.0,
        panEnabled: _zoomed,
        onInteractionStart: _onInteractionStart,
        onInteractionUpdate: _onInteractionUpdate,
        onInteractionEnd: _onInteractionEnd,
        child: widget.child,
      ),
    );
  }
}
