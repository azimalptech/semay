// The arithmetic behind "one percentage for the whole job". A carousel post
// uploads N files and a reel uploads video + thumbnail; weighted by FILE the
// bar lies (a 30 KB thumbnail is not half the job of a 40 MB video), and
// per-file it restarts. These pin the weighting, the throttling and the
// dispose guard.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/upload_progress.dart';

void main() {
  group('UploadProgress', () {
    test('percent floors, so only a finished upload reads 100', () {
      expect(const UploadProgress(sentBytes: 0, totalBytes: 100).percent, 0);
      expect(const UploadProgress(sentBytes: 999, totalBytes: 1000).percent, 99);
      expect(
        const UploadProgress(sentBytes: 1000, totalBytes: 1000).percent,
        100,
      );
      expect(
        const UploadProgress(sentBytes: 1000, totalBytes: 1000).isComplete,
        isTrue,
      );
    });

    test('a job of unknown size reports 0, not NaN', () {
      const p = UploadProgress(sentBytes: 10, totalBytes: 0);
      expect(p.fraction, 0);
      expect(p.percent, 0);
    });
  });

  group('UploadProgressAggregator', () {
    test('weights by bytes across files, never restarting per file', () {
      final seen = <int>[];
      // A reel: a 40 MB video followed by a 40 KB thumbnail. By file count
      // the thumbnail would be half the job.
      const video = 40 * 1024 * 1024;
      const thumb = 40 * 1024;
      final job = UploadProgressAggregator(
        totalBytes: video + thumb,
        onProgress: (p) => seen.add(p.percent),
      );

      final videoSlot = job.addFile(video);
      videoSlot.report(video ~/ 4, video);
      videoSlot.report(video ~/ 2, video);
      videoSlot.report(video, video);
      videoSlot.complete();
      // The whole video is only ~99.9 % of the job — it must NOT read 100
      // while the thumbnail is still to come.
      expect(job.progress.percent, 99);

      final thumbSlot = job.addFile(thumb);
      thumbSlot.report(thumb, thumb);
      thumbSlot.complete();

      expect(job.progress.percent, 100);
      expect(seen, [24, 49, 99, 100]);
      expect(seen, orderedEquals(List.of(seen)..sort()), reason: 'monotonic');
    });

    test('a four-photo carousel fills one bar once', () {
      final seen = <int>[];
      final job = UploadProgressAggregator(
        totalBytes: 400,
        onProgress: (p) => seen.add(p.percent),
      );
      for (var i = 0; i < 4; i++) {
        final slot = job.addFile(100);
        slot.report(50, 100);
        slot.report(100, 100);
        slot.complete();
      }
      expect(seen, [12, 25, 37, 50, 62, 75, 87, 100]);
    });

    test('emits only when the percentage changes', () {
      var emissions = 0;
      final job = UploadProgressAggregator(
        totalBytes: 1000,
        onProgress: (_) => emissions++,
      );
      final slot = job.addFile(1000);
      // Ten chunks inside the same percent. The first emits (0 % — that is
      // what flips a surface from "starting" to a determinate bar); the other
      // eight are silent.
      for (var i = 1; i <= 9; i++) {
        slot.report(i, 1000);
      }
      expect(emissions, 1);
      slot.report(10, 1000); // crosses into 1 %
      expect(emissions, 2);
    });

    test('never walks backwards', () {
      final seen = <int>[];
      final job = UploadProgressAggregator(
        totalBytes: 100,
        onProgress: (p) => seen.add(p.percent),
      );
      final slot = job.addFile(100);
      slot.report(80, 100);
      slot.report(20, 100); // a retried chunk must not un-fill the bar
      expect(seen, [80]);
      expect(job.progress.percent, 80);
    });

    test('a file bigger than declared grows the job instead of pinning at 100', () {
      final job = UploadProgressAggregator(totalBytes: 100);
      final slot = job.addFile(100);
      slot.report(100, 200); // dio says the body is really 200 bytes
      expect(job.totalBytes, 200);
      expect(job.progress.percent, 50);
    });

    test('close() makes every later callback inert — the dispose guard', () {
      final seen = <int>[];
      final job = UploadProgressAggregator(
        totalBytes: 100,
        onProgress: (p) => seen.add(p.percent),
      );
      final slot = job.addFile(100);
      slot.report(50, 100);
      job.close();
      // The upload is not cancellable: these keep arriving after the screen
      // is gone. Nothing may reach the callback (a setState on a defunct
      // State is the crash this prevents).
      slot.report(75, 100);
      slot.complete();
      expect(seen, [50]);
      expect(job.isClosed, isTrue);
    });
  });

  group('MediaTooLargeException', () {
    test('carries the cap in MB for the localised message', () {
      const e = MediaTooLargeException(100 * 1024 * 1024);
      expect(e.limitMegabytes, 100);
    });
  });
}
