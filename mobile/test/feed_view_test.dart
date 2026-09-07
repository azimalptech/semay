// Reels-in-feed: the home feed keys each PostCard by post id, and a reel
// tile fetches its file only once it qualifies to play. These pin both
// against a plain FeedView with every network-backed provider stubbed —
// nothing here reaches a platform channel, which is itself one of the
// assertions (see the first test).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/features/feed/feed_providers.dart';
import 'package:semay/features/feed/feed_view.dart';
import 'package:semay/features/profile/notifications_providers.dart';
import 'package:semay/features/shared/post_interaction_providers.dart';
import 'package:semay/features/shared/story_bar_provider.dart';
import 'package:semay/features/shared/widgets/post_card.dart';

PostDoc _post(String id, {String type = 'image', List<String> media = const []}) =>
    PostDoc({
      'id': id,
      'storeId': 'store-1',
      'type': type,
      'caption': '',
      'thumbnailUrl': '',
      'mediaUrls': media,
      'createdAt': '2026-09-07T10:00:00.000Z',
      'likesCount': 0,
      'viewsCount': 0,
      'sentCount': 0,
      'likedByMe': false,
      'savedByMe': false,
    });

// No image URLs: the card paints its placeholder square, so the test never
// starts an image fetch either.
PostDoc _photo(String id) => _post(id);

PostDoc _reel(String id) =>
    _post(id, type: 'reel', media: ['http://127.0.0.1:1/media/reels/$id.mp4']);

/// The feed as the app sees it, minus the network: what [FeedNotifier]
/// would hold after its first page, mutable from the test.
class _FakeFeed extends FeedNotifier {
  _FakeFeed(this.initial);

  final List<PostDoc> initial;

  @override
  Future<List<PostDoc>> build() async {
    hasMore = false;
    return initial;
  }

  @override
  Future<void> loadMore() async {}

  void show(List<PostDoc> posts) => state = AsyncData(posts);
}

class _Harness {
  _Harness(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;
  // Method names MediaCache's cache manager asked path_provider for — its
  // first act on any fetch is resolving its directories, so this is the
  // earliest sign a reel file download started.
  final pathProviderCalls = <String>[];

  _FakeFeed get feed => container.read(feedNotifierProvider.notifier) as _FakeFeed;

  State cardState(String postId) =>
      tester.state(find.byKey(ValueKey(postId), skipOffstage: false));

  Future<void> mount() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FeedView(storyRoutePrefix: '/home/story')),
      ),
    );
    // Lets the fake notifier's async build resolve and the first cards lay out.
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _feedTest(
  String description,
  List<PostDoc> initial, {
  required Size window,
  required Future<void> Function(WidgetTester tester, _Harness h) body,
}) {
  testWidgets(description, (tester) async {
    // Fires visibility callbacks on the next frame instead of a 500 ms timer
    // (the package's own advice for tests).
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        feedNotifierProvider.overrideWith(() => _FakeFeed(initial)),
        // One ring, not none: with an empty bar _StoryRingBarState never
        // touches its late `_spin` controller until dispose(), where creating
        // it trips a deactivated-ancestor assertion (pre-existing, outside
        // this change). Avatar-less and already seen, so no image fetch.
        storyBarProvider.overrideWith(
          (ref) async => [
            StoryRingInfo(
              storeId: 'store-1',
              storeName: 'Store',
              avatarUrl: '',
              hasStories: true,
              seen: true,
              isOwn: false,
            ),
          ],
        ),
        unreadNotificationCountProvider.overrideWithValue(0),
        l10nProvider.overrideWithValue(const S(false)),
        postDocProvider.overrideWith(
          (ref, id) => const Stream<Map<String, dynamic>?>.empty(),
        ),
        storeSummaryProvider.overrideWith(
          (ref, id) => Stream<Map<String, dynamic>?>.value(null),
        ),
        pendingInteractionsProvider.overrideWith(
          (ref, id) => Stream.value((views: 0, sent: 0, shares: 0)),
        ),
      ],
    );
    final h = _Harness(tester, container);
    // Answers nothing rather than a real directory: the lazy tile never
    // asks, and an eager one must trip here instead of writing a cache to
    // disk and firing an HTTP request from a unit test.
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      h.pathProviderCalls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    await h.mount();

    await body(tester, h);

    // Take the tree down first: that cancels the cards' view-dwell timers,
    // then the container's disposal cancels Riverpod's zero-length refresh
    // timer — either would otherwise trip the no-pending-timers check.
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}

void main() {
  // A 400-wide window makes each card ~470 tall (square media plus the
  // action and date rows) under a ~55 top bar and the 116 story bar: in a
  // 520-tall window the first card's square is ~85% on screen and the second
  // card starts past the viewport, built only by the ListView's cache
  // extent — 0% of its square visible, well below the 60% autoplay line.
  _feedTest(
    'a reel built off screen does not fetch its file',
    [_photo('p1'), _reel('r1')],
    window: const Size(400, 520),
    body: (tester, h) async {
      // The reel card exists — this is not a "never built" pass.
      expect(h.cardState('r1'), isA<State<PostCard>>());
      expect(find.byType(VideoPlayer, skipOffstage: false), findsNothing);
      expect(
        h.pathProviderCalls,
        isEmpty,
        reason: 'the tile fetched its file on mount, before it could play',
      );
    },
  );

  _feedTest(
    'a card\'s State follows its post when a newer post shifts the list',
    [_photo('p1'), _photo('p2'), _photo('p3')],
    // Tall enough that all four cards stay built after the shift.
    window: const Size(400, 2000),
    body: (tester, h) async {
      final before = {for (final id in ['p1', 'p2', 'p3']) id: h.cardState(id)};

      // What every cold start and pull-to-refresh does once any store has
      // published: the same posts, one row further down.
      h.feed.show([_photo('p0'), _photo('p1'), _photo('p2'), _photo('p3')]);
      await tester.pump(const Duration(milliseconds: 20));

      for (final id in before.keys) {
        expect(
          identical(before[id], h.cardState(id)),
          isTrue,
          reason: '$id kept its State (the reel controller, carousel page and '
              'view dwell live there) instead of inheriting the one at its old '
              'index',
        );
      }
      final fresh = h.cardState('p0');
      expect(before.values.any((s) => identical(s, fresh)), isFalse);
    },
  );
}
