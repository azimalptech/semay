// Reels-in-feed: GET /feed now returns every post type in one createdAt
// stream, so a reel row flows through the same parse path as a photo row
// (postsFromResponse -> normalizePost -> PostCard). These pin the pure parts
// of that path — no platform channels, so no video_player/cache manager.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/json_ext.dart';
import 'package:semay/features/feed/feed_providers.dart';
import 'package:semay/features/search/search_screen.dart'
    show mergeUniquePosts;

// Fresh maps per call: normalizePost mutates its argument.
Map<String, dynamic> imageRow() => {
  'id': 'img-1',
  'storeId': 'store-1',
  'type': 'image',
  'caption': 'photo',
  'price': '19.99',
  'thumbnailUrl': '',
  'createdAt': '2026-09-07T10:00:00.000Z',
  'media': [
    {'url': '/media/posts/a.jpg', 'position': 0, 'thumbnailUrl': null},
  ],
  'likedByMe': false,
  'savedByMe': false,
};

// The common wire shape for a reel: thumbnailUrl '' (web composer has no
// thumbnail generator) and a single .mp4 media row.
Map<String, dynamic> reelRow({String id = 'reel-1'}) => {
  'id': id,
  'storeId': 'store-1',
  'type': 'reel',
  'caption': 'clip',
  'price': null,
  'thumbnailUrl': '',
  'createdAt': '2026-09-07T09:00:00.000Z',
  'media': [
    {'url': '/media/reels/x.mp4', 'position': 0, 'thumbnailUrl': null},
  ],
  'likedByMe': false,
  'savedByMe': false,
};

void main() {
  group('postsFromResponse', () {
    test('keeps a reel row in the feed, in server order', () {
      final docs = postsFromResponse({
        'posts': [imageRow(), reelRow()],
      });

      expect(docs.map((d) => d.id).toList(), ['img-1', 'reel-1']);
      expect(docs[1].data()['type'], 'reel');
    });

    test('an empty or missing posts list parses to no rows', () {
      expect(postsFromResponse({'posts': []}), isEmpty);
      expect(postsFromResponse({}), isEmpty);
    });
  });

  group('normalizePost on a reel row', () {
    test('synthesizes mediaUrls from the video media row', () {
      final post = normalizePost(reelRow());

      expect(post['mediaUrls'], ['/media/reels/x.mp4']);
      expect(post['type'], 'reel');
      expect(post['thumbnailUrl'], '');
      expect(post['price'], isNull);
    });

    test('still flattens a decimal-string price on a photo row', () {
      expect(normalizePost(imageRow())['price'], 19.99);
    });
  });

  group('mergeUniquePosts', () {
    test('collapses a reel present in both /feed and /reels to one entry', () {
      final feed = postsFromResponse({
        'posts': [imageRow(), reelRow()],
      });
      final reels = postsFromResponse({
        'posts': [reelRow(), reelRow(id: 'reel-2')],
      });

      final merged = mergeUniquePosts([feed, reels]);

      expect(merged.map((d) => d.id).toList(), ['img-1', 'reel-1', 'reel-2']);
    });

    test('keeps the first occurrence, so the feed row wins', () {
      final fromFeed = JsonDoc({'id': 'reel-1', 'caption': 'feed copy'});
      final fromReels = JsonDoc({'id': 'reel-1', 'caption': 'reels copy'});

      final merged = mergeUniquePosts([
        [fromFeed],
        [fromReels],
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.data()['caption'], 'feed copy');
    });
  });
}
