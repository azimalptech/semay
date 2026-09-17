// The store profile ring's source of truth. The server drops expired rows
// from GET /stores/:id/stories and publishes nothing when a story expires,
// so the provider has to notice that moment itself — and let go of the
// timer with the screen.

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/session.dart';
import 'package:semay/core/shell_tab.dart';
import 'package:semay/features/shared/story_bar_provider.dart';
import 'package:semay/features/story_viewer/story_providers.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';
const _stories = 'GET /stores/$_storeId/stories';
const _rings = 'GET /stories/rings';

Map<String, dynamic> _story(String id, Duration untilExpiry) => {
  'id': id,
  'storeId': _storeId,
  'mediaUrl': 'http://127.0.0.1:1/media/stories/$id.jpg',
  'mediaType': 'image',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'expiresAt': DateTime.now().add(untilExpiry).toUtc().toIso8601String(),
};

Map<String, dynamic> _ring({required bool seen}) => {
  'storeId': _storeId,
  'storeName': 'Audit Store',
  'avatarUrl': '',
  'hasStories': true,
  'seen': seen,
  'isOwn': false,
};

void main() {
  late FakeApi api;
  late ProviderContainer container;
  late List<Map<String, dynamic>> stories;
  late List<Map<String, dynamic>> rings;

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      sessionControllerProvider.overrideWith(() => FakeSession()),
    ],
  );

  setUp(() {
    stories = [];
    rings = [];
    api = FakeApi()
      ..onGet = (path) {
        if (path == '/stores/$_storeId/stories') {
          return {'stories': List.of(stories)};
        }
        if (path == '/stories/rings') return {'rings': List.of(rings)};
        return const {};
      };
    container = makeContainer();
  });

  tearDown(() => container.dispose());

  /// Subscribes (the provider is autoDispose) and waits for both reads.
  Future<StoreStoryState> subscribe(ProviderContainer c) async {
    final sub = c.listen(storeHasActiveStoriesProvider(_storeId), (_, _) {});
    addTearDown(sub.close);
    await c.read(storeStoriesProvider(_storeId).future);
    await c.read(storyBarProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return c.read(storeHasActiveStoriesProvider(_storeId));
  }

  test('no active story → no ring', () async {
    final state = await subscribe(container);
    expect(state.hasStories, isFalse);
    expect(state.seen, isFalse);
  });

  test('an active story lights the ring; seen comes from the rings list', () async {
    stories.add(_story('s1', const Duration(hours: 23)));
    rings.add(_ring(seen: true));
    final state = await subscribe(container);
    expect(state.hasStories, isTrue);
    expect(state.seen, isTrue);
  });

  test('a store missing from the rings list counts as unseen', () async {
    stories.add(_story('s1', const Duration(hours: 23)));
    final state = await subscribe(container);
    expect(state.hasStories, isTrue);
    expect(state.seen, isFalse);
  });

  test('the ring drops on its own when the last story crosses expiresAt', () async {
    stories.add(_story('s1', const Duration(milliseconds: 300)));
    expect((await subscribe(container)).hasStories, isTrue);
    expect(api.count(_stories), 1);

    // What the server answers once the row has expired.
    stories.clear();
    // 300 ms to the boundary, plus the provider's one-second margin.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(api.count(_stories), 2, reason: 're-read at expiry, no user action');
    expect(
      container.read(storeHasActiveStoriesProvider(_storeId)).hasStories,
      isFalse,
    );
  });

  test('disposing cancels the expiry re-read', () async {
    stories.add(_story('s1', const Duration(milliseconds: 300)));
    final own = makeContainer();
    await subscribe(own);
    expect(api.count(_stories), 1);

    own.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(api.count(_stories), 1, reason: 'the timer died with the provider');
  });

  test('returning to the foreground re-reads the list', () async {
    stories.add(_story('s1', const Duration(hours: 23)));
    await subscribe(container);
    expect(api.count(_stories), 1);

    container.read(appInForegroundProvider.notifier).set(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.count(_stories), 1, reason: 'backgrounding is not a refresh');

    container.read(appInForegroundProvider.notifier).set(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.count(_stories), 2);
  });

  test('resume re-reads the rings too: a story posted while away is not muted', () async {
    // `seen` is server-computed as seenAt >= latestAt (stories/service.ts), so
    // a new story makes a cached `seen: true` wrong the instant it lands.
    // Re-reading only the per-store list left the ring MUTED for a story the
    // user had never seen — "muted when all seen" exactly inverted.
    stories.add(_story('s1', const Duration(hours: 23)));
    rings.add(_ring(seen: true));
    expect((await subscribe(container)).seen, isTrue);
    expect(api.count(_rings), 1);

    // Watched to the end, backgrounded, then the store posted again.
    stories.add(_story('s2', const Duration(hours: 24)));
    rings
      ..clear()
      ..add(_ring(seen: false));
    container.read(appInForegroundProvider.notifier).set(false);
    container.read(appInForegroundProvider.notifier).set(true);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(api.count(_rings), 2, reason: 'both inputs, not just the list');
    final state = container.read(storeHasActiveStoriesProvider(_storeId));
    expect(state.hasStories, isTrue);
    expect(state.seen, isFalse, reason: 'unseen story → gradient, not muted');
  });

  test('the ring does not pop in: it starts from the rings list', () async {
    // hasStories used to read `storeStoriesProvider.value ?? []`, so for the
    // whole first GET the header drew a bare avatar and the gradient appeared
    // a beat later. The rings list is keep-alive and normally already holds
    // this store's answer.
    final gate = Completer<Map<String, dynamic>>();
    rings.add(_ring(seen: false));
    api.onGet = (path) {
      if (path == '/stores/$_storeId/stories') return gate.future;
      if (path == '/stories/rings') return {'rings': List.of(rings)};
      return const {};
    };
    final sub = container.listen(
      storeHasActiveStoriesProvider(_storeId),
      (_, _) {},
    );
    addTearDown(sub.close);
    await container.read(storyBarProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final early = container.read(storeHasActiveStoriesProvider(_storeId));
    expect(early.hasStories, isTrue, reason: 'drawn from the rings list');
    expect(early.seen, isFalse);

    // …and the exact per-store answer still wins once it lands.
    gate.complete({'stories': const <Map<String, dynamic>>[]});
    await container.read(storeStoriesProvider(_storeId).future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      container.read(storeHasActiveStoriesProvider(_storeId)).hasStories,
      isFalse,
      reason: 'the per-store list is the source of truth once it is in',
    );
  });
}
