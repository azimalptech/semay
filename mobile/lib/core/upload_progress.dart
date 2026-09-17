import 'dart:math';

/// Media-upload progress, shared by every surface that sends bytes to the
/// server (post composer, story composer, store avatar, the chat outbox).
///
/// Two shapes on purpose:
///  * [UploadByteProgress] is the raw per-request callback — the same
///    `(sent, total)` shape Dio's `onSendProgress` hands us, so
///    `PostsService.uploadMedia` can forward it untouched.
///  * [UploadProgressAggregator] turns N of those into ONE percentage for a
///    job, weighted by BYTES, not by file count: a carousel of four photos
///    and a reel's video + thumbnail otherwise showed a bar that restarted
///    per file (and, weighted by count, jumped from 50 % to 100 % the instant
///    a 30 KB thumbnail followed a 40 MB video).
typedef UploadByteProgress = void Function(int sent, int total);

/// A file the app refuses to send at all (the 100 MB video cap enforced by
/// PostsService/StoriesService/ChatService). A typed exception, not
/// `Exception('Video must be under 100MB')`: that string reached users
/// verbatim in a tk/ru-only app — see `describeUploadError` in api_client.dart.
class MediaTooLargeException implements Exception {
  const MediaTooLargeException(this.limitBytes);

  final int limitBytes;
  int get limitMegabytes => limitBytes ~/ (1024 * 1024);

  @override
  String toString() => 'MediaTooLargeException($limitBytes)';
}

typedef UploadProgressCallback = void Function(UploadProgress progress);

class UploadProgress {
  const UploadProgress({required this.sentBytes, required this.totalBytes});

  final int sentBytes;
  final int totalBytes;

  /// 0..1. A job whose size is unknown (0 bytes declared) reports 0 rather
  /// than NaN — callers show an indeterminate spinner for that.
  double get fraction {
    if (totalBytes <= 0) return 0;
    final f = sentBytes / totalBytes;
    return f.isNaN ? 0 : f.clamp(0.0, 1.0);
  }

  /// Floored, so a job that is 99.6 % sent never reads "100 %" while the
  /// last chunk is still on the wire — only a finished job shows 100.
  int get percent => fraction >= 1 ? 100 : (fraction * 100).floor();

  bool get isComplete => totalBytes > 0 && sentBytes >= totalBytes;

  @override
  String toString() => 'UploadProgress($sentBytes/$totalBytes, $percent%)';
}

/// One file inside an aggregated job. [report] is what goes to
/// `uploadMedia(onProgress: ...)`; [complete] force-fills the slot for a file
/// whose upload returned (a server that never emitted a final chunk callback
/// must not leave the bar at 98 %).
class UploadSlot {
  UploadSlot._(this._owner, this._index);

  final UploadProgressAggregator _owner;
  final int _index;

  void report(int sent, int total) => _owner._report(_index, sent, total);
  void complete() => _owner._complete(_index);
}

class UploadProgressAggregator {
  UploadProgressAggregator({required int totalBytes, this.onProgress})
    : _totalBytes = max(totalBytes, 0);

  final UploadProgressCallback? onProgress;

  int _totalBytes;
  final List<int> _slotSize = [];
  final List<int> _slotSent = [];

  /// Set by [close]. Every surface that can be left mid-upload (the composers
  /// are pop-able, the avatar picker's screen is) closes its aggregator in
  /// `dispose`, so a callback that lands after the widget is gone cannot
  /// reach a `setState` on a defunct State — the classic crash here.
  bool _closed = false;
  int? _lastPercent;

  int get totalBytes => _totalBytes;
  int get sentBytes => _slotSent.fold(0, (a, b) => a + b);
  bool get isClosed => _closed;
  UploadProgress get progress =>
      UploadProgress(sentBytes: sentBytes, totalBytes: _totalBytes);

  /// Registers a file of [fileBytes] and returns its slot. Sizes come from
  /// `XFile.length()` / the byte array, taken before the job starts, which is
  /// what makes the weighting possible at all.
  UploadSlot addFile(int fileBytes) {
    _slotSize.add(max(fileBytes, 0));
    _slotSent.add(0);
    return UploadSlot._(this, _slotSize.length - 1);
  }

  void _report(int index, int sent, int total) {
    if (_closed) return;
    // A file that turns out bigger than declared (re-encoded on the way out,
    // a stale length) grows the job total instead of pinning the bar at 100 %
    // early.
    if (total > _slotSize[index]) {
      _totalBytes += total - _slotSize[index];
      _slotSize[index] = total;
    }
    final capped = sent.clamp(0, _slotSize[index] > 0 ? _slotSize[index] : sent);
    if (capped <= _slotSent[index]) return; // monotonic: never walk backwards
    _slotSent[index] = capped;
    _emit();
  }

  void _complete(int index) {
    if (_closed) return;
    if (_slotSent[index] >= _slotSize[index]) return;
    _slotSent[index] = _slotSize[index];
    _emit();
  }

  /// Emits only when the whole-job percentage actually changes — a 40 MB reel
  /// at 64 KB a chunk is ~640 callbacks, and every one of them used to be a
  /// `setState`.
  void _emit() {
    final p = progress;
    if (_lastPercent == p.percent) return;
    _lastPercent = p.percent;
    onProgress?.call(p);
  }

  /// Stops all further emissions. Idempotent.
  void close() => _closed = true;
}
