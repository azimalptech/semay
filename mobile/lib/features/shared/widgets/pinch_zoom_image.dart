import 'package:flutter/material.dart';

/// Instagram-style pinch-to-zoom on a post image: pinch/pan while your
/// fingers are down, elastic snap back to the grid the moment you lift them.
///
/// Built on Flutter's Overlay rather than InteractiveViewer: InteractiveViewer
/// clips its content to its own layout box by design (it's a viewport), so a
/// zoomed image can never grow past the original square tile. This instead
/// hides the real tile and floats a scaled copy in the app's root Overlay —
/// above and unclipped by every sibling/ancestor — positioned to grow
/// outward from the tile's on-screen rect as the pinch progresses.
///
/// Gesture tracking uses a raw Listener rather than GestureDetector's
/// onScale* family: onScale claims the whole gesture the instant it starts,
/// including ordinary single-finger touches, which would fight the carousel
/// PageView this usually sits inside for swipe gestures (the exact bug an
/// earlier version of this widget had). Listener never enters the gesture
/// arena at all, so a single-finger drag still reaches the PageView
/// untouched — this widget only ever acts once a second finger is down.
class PinchZoomImage extends StatefulWidget {
  const PinchZoomImage({super.key, required this.child, this.onZoomStart});

  final Widget child;

  /// Fired once per pinch gesture, the moment a second finger goes down —
  /// used by post-detail screens as one of the "actually engaged with this
  /// post" signals for view-counting (see PostsService.recordView).
  final VoidCallback? onZoomStart;

  @override
  State<PinchZoomImage> createState() => _PinchZoomImageState();
}

class _PinchZoomImageState extends State<PinchZoomImage>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boxKey = GlobalKey();
  final Map<int, Offset> _pointers = {};
  OverlayEntry? _overlayEntry;
  late final AnimationController _resetController = AnimationController(
    vsync: this,
  )..addListener(_onResetTick);

  Rect? _originalRect;
  double _initialSpan = 1;
  Offset _initialFocal = Offset.zero;
  double _scale = 1.0;
  Offset _panOffset = Offset.zero;
  double? _resetFromScale;
  Offset? _resetFromOffset;

  @override
  void dispose() {
    _resetController.dispose();
    _overlayEntry?.remove();
    super.dispose();
  }

  Rect _measureOriginalRect() {
    final renderBox = _boxKey.currentContext!.findRenderObject() as RenderBox;
    return renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) _startZoom();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    if (_pointers.length >= 2 && _overlayEntry != null) _updateZoom();
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2 && _overlayEntry != null) _endZoom();
  }

  void _startZoom() {
    widget.onZoomStart?.call();
    _resetController.stop();
    // A re-pinch that starts before the previous snap-back animation
    // finishes stops it mid-flight — _onResetTick (which normally removes
    // the entry once the animation completes) never runs for it, so
    // without this the old entry stays inserted in the root Overlay
    // forever, floating above every screen in the app from then on.
    _overlayEntry?.remove();
    _resetFromScale = null;
    _resetFromOffset = null;
    _originalRect = _measureOriginalRect();
    final points = _pointers.values.toList();
    _initialSpan = (points[0] - points[1]).distance.clamp(1.0, double.infinity);
    _initialFocal = (points[0] + points[1]) / 2;
    _scale = 1.0;
    _panOffset = Offset.zero;
    final entry = OverlayEntry(builder: _buildOverlay);
    _overlayEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    setState(() {});
  }

  void _updateZoom() {
    final points = _pointers.values.toList();
    if (points.length < 2) return;
    final span = (points[0] - points[1]).distance;
    final focal = (points[0] + points[1]) / 2;
    setState(() {
      _scale = (span / _initialSpan).clamp(1.0, 5.0);
      _panOffset = focal - _initialFocal;
    });
    _overlayEntry?.markNeedsBuild();
  }

  void _endZoom() {
    _resetFromScale = _scale;
    _resetFromOffset = _panOffset;
    _resetController.value = 0;
    _resetController.animateTo(
      1,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  void _onResetTick() {
    final fromScale = _resetFromScale;
    final fromOffset = _resetFromOffset;
    if (fromScale == null || fromOffset == null) return;
    final t = _resetController.value;
    setState(() {
      _scale = fromScale + (1.0 - fromScale) * t;
      _panOffset = fromOffset * (1 - t);
    });
    _overlayEntry?.markNeedsBuild();
    if (t >= 1.0) {
      _resetFromScale = null;
      _resetFromOffset = null;
      _overlayEntry?.remove();
      _overlayEntry = null;
      _originalRect = null;
    }
  }

  Widget _buildOverlay(BuildContext context) {
    final rect = _originalRect!;
    final scaledWidth = rect.width * _scale;
    final scaledHeight = rect.height * _scale;
    return Positioned(
      left: rect.left + _panOffset.dx - (scaledWidth - rect.width) / 2,
      top: rect.top + _panOffset.dy - (scaledHeight - rect.height) / 2,
      width: scaledWidth,
      height: scaledHeight,
      child: IgnorePointer(child: widget.child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: Opacity(
        // The Overlay entry shows the zoomed copy — hide the real tile
        // underneath while that's active so there isn't a doubled image.
        opacity: _overlayEntry != null ? 0 : 1,
        child: KeyedSubtree(key: _boxKey, child: widget.child),
      ),
    );
  }
}
