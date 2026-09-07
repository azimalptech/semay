import 'dart:async';

import 'package:flutter/foundation.dart';

/// When a post or reel counts as viewed: [threshold] on screen, or an
/// explicit signal (a like, a pinch-zoom) sooner. "On screen" is the
/// surface showing *and* the app in the foreground — a dwell that began
/// 0.3 s before the screen locked must not finish counting behind it, which
/// a bare timer would (Android keeps running it; iOS delivers it on
/// return). Fires at most once per instance — that only stops one screen
/// from recording the same dwell twice; the 30-minute re-count window is
/// InteractionBuffer's job, and still applies across surfaces (feed card,
/// detail view, reel player).
///
/// One class for all three surfaces so the threshold can't drift again —
/// they were 2 s each, hard-coded separately, while the feed counted
/// nothing at all.
class ViewDwell {
  ViewDwell(this._onView, {required bool inForeground})
    : _inForeground = inForeground;

  static const threshold = Duration(milliseconds: 800);

  final VoidCallback _onView;
  Timer? _timer;
  bool _recorded = false;
  bool _onScreen = false;
  bool _inForeground;

  /// The surface is showing (again): arms the dwell. A no-op once this
  /// instance has recorded.
  void start() {
    _onScreen = true;
    _arm();
  }

  /// Off screen before the threshold — this dwell doesn't count; the next
  /// [start] begins a fresh one.
  void cancel() {
    _onScreen = false;
    _timer?.cancel();
  }

  /// appInForegroundProvider's value. Leaving the foreground is [cancel]
  /// without forgetting the surface is showing; returning starts a fresh
  /// dwell only if it still is.
  set inForeground(bool value) {
    if (value == _inForeground) return;
    _inForeground = value;
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    if (_recorded || !_onScreen || !_inForeground) return;
    _timer = Timer(threshold, record);
  }

  /// Counts now, whether the timer fired or the user liked/zoomed first.
  void record() {
    _timer?.cancel();
    if (_recorded) return;
    _recorded = true;
    _onView();
  }
}
