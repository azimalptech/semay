// The seam behind the "liked/saved only update after a restart" bug: a
// provider that has to re-READ server state must refetch when the outbox says
// the write LANDED, not when it was queued (PostsService.toggleLike returns
// after the enqueue) and not on every outbox change (that also fires on
// enqueue and on failed attempts).
//
// outboxCompletedProvider is the injectable form of that signal, so this
// exercises the real refetchWhenOutboxSends against a driven stream — no
// SQLite, no network, no platform channels.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/outbox.dart';

const _debounce = Duration(milliseconds: 10);

/// Long enough for the debounce timer plus the re-run it schedules.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  late StreamController<OutboxKind> completed;
  late int fetches;
  late ProviderContainer container;

  /// Stands in for likedPostIdsProvider: same wiring, a counter instead of a
  /// network read.
  final probe = FutureProvider<int>((ref) async {
    refetchWhenOutboxSends(
      ref,
      const {OutboxKind.like, OutboxKind.unlike},
      debounce: _debounce,
    );
    return ++fetches;
  }, isAutoDispose: true);

  setUp(() {
    completed = StreamController<OutboxKind>.broadcast();
    fetches = 0;
    container = ProviderContainer(
      overrides: [outboxCompletedProvider.overrideWithValue(completed.stream)],
    );
  });

  tearDown(() {
    container.dispose();
    completed.close();
  });

  test('a completed like refetches; an unrelated kind does not', () async {
    final sub = container.listen(probe, (_, _) {});
    addTearDown(sub.close);
    expect(await container.read(probe.future), 1);

    // A chat message draining is not this provider's business.
    completed.add(OutboxKind.message);
    await _settle();
    expect(fetches, 1);

    completed.add(OutboxKind.like);
    await _settle();
    expect(fetches, 2);
    expect(await container.read(probe.future), 2);

    // Unlike counts too — the post has to leave the grid.
    completed.add(OutboxKind.unlike);
    await _settle();
    expect(fetches, 3);
  });

  test('a burst of toggles collapses into one refetch', () async {
    final sub = container.listen(probe, (_, _) {});
    addTearDown(sub.close);
    await container.read(probe.future);

    completed
      ..add(OutboxKind.like)
      ..add(OutboxKind.unlike)
      ..add(OutboxKind.like);
    await _settle();

    expect(fetches, 2, reason: 'one refetch after the burst, not one per tap');
  });

  test('nothing refetches once the screen watching it is gone', () async {
    final sub = container.listen(probe, (_, _) {});
    await container.read(probe.future);
    expect(fetches, 1);

    // The grid was popped: the auto-disposed provider goes with it, and so
    // must its subscription to the outbox.
    sub.close();
    await _settle();

    completed.add(OutboxKind.like);
    await _settle();
    expect(fetches, 1);
  });

  test('a replay that only lands much later still refetches', () async {
    final sub = container.listen(probe, (_, _) {});
    addTearDown(sub.close);
    await container.read(probe.future);

    // Offline the whole time, then signal comes back and drain() finally
    // succeeds — the completion is what matters, not how long it took.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(fetches, 1);

    completed.add(OutboxKind.like);
    await _settle();
    expect(fetches, 2);
  });
}
