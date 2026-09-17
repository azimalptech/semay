// The store profile used to draw the gradient story ring around every avatar,
// story or no story, for visitors and for the store's own admin, and the
// ringed avatar opened nothing. These drive the REAL StoreProfileScreen under
// a GoRouter (the tap pushes the viewer route) with the network stubbed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/session.dart';
import 'package:semay/core/theme.dart';
import 'package:semay/features/feed/feed_providers.dart';
import 'package:semay/features/shared/widgets/story_ring.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/features/store_profile/store_profile_screen.dart';
import 'package:semay/features/story_viewer/story_viewer_screen.dart'
    show StoryViewerArgs;
import 'package:semay/services/chat_service.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';
const _s = S(false);

final _store = <String, dynamic>{
  'id': _storeId,
  'name': 'Audit Store',
  'tagline': '',
  'address': '',
  'phone': '',
  'avatarUrl': '',
  'postsCount': 0,
  'reelsCount': 0,
  'likesCount': 0,
};

Map<String, dynamic> _story(String id) => {
  'id': id,
  'storeId': _storeId,
  'mediaUrl': 'http://127.0.0.1:1/media/stories/$id.jpg',
  'mediaType': 'image',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'expiresAt': DateTime.now()
      .add(const Duration(hours: 23))
      .toUtc()
      .toIso8601String(),
};

Map<String, dynamic> _ring({
  required bool hasStories,
  required bool seen,
  bool isOwn = false,
}) => {
  'storeId': _storeId,
  'storeName': 'Audit Store',
  'avatarUrl': '',
  'hasStories': hasStories,
  'seen': seen,
  'isOwn': isOwn,
};

class _NoPosts extends StorePostsNotifier {
  _NoPosts(super.storeId);
  @override
  Future<List<PostDoc>> build() async => const [];
}

class _NoReels extends StoreReelsNotifier {
  _NoReels(super.storeId);
  @override
  Future<List<PostDoc>> build() async => const [];
}

final Finder _ringFinder = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is StoryRingPainter,
);

/// The header ring's painter — the one place the ring state is drawn.
StoryRingPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_ringFinder).painter! as StoryRingPainter;

Finder get _avatarTap =>
    find.ancestor(of: _ringFinder, matching: find.byType(GestureDetector)).first;

class _Harness {
  _Harness(this.api, this.pushed);

  final FakeApi api;

  /// Viewer routes the screen pushed: (path, extra).
  final List<(String, Object?)> pushed;
}

/// A ChatService whose first call fails, the way a dead network makes it.
class _OfflineChat implements ChatService {
  @override
  Future<String> createOrGetChat(String storeId) async =>
      throw ApiException(null, 'REQUEST_FAILED');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required bool ownStore,
  List<Map<String, dynamic>> stories = const [],
  List<Map<String, dynamic>> rings = const [],
  ChatService? chat,
}) async {
  final api = FakeApi()
    ..onGet = (path) {
      if (path == '/stories/rings') return {'rings': rings};
      if (path == '/stores/$_storeId/stories') return {'stories': stories};
      if (path == '/users/me') {
        return {
          'user': {'id': 'u1', 'name': 'Azim', 'language': 'tk'},
        };
      }
      return const {};
    };
  final pushed = <(String, Object?)>[];
  Widget viewer(BuildContext context, GoRouterState state) {
    pushed.add((state.uri.path, state.extra));
    return const Scaffold(body: Text('viewer'));
  }

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const StoreProfileScreen(storeId: _storeId),
      ),
      GoRoute(path: '/home/story/:storeId', builder: viewer),
      GoRoute(path: '/admin/home/story/:storeId', builder: viewer),
    ],
  );
  addTearDown(router.dispose);
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionControllerProvider.overrideWith(
          () => ownStore
              ? FakeSession(role: 'admin', storeIds: const [_storeId])
              : FakeSession(),
        ),
        storeDocProvider(_storeId).overrideWith((ref) => Stream.value(_store)),
        storePostsProvider(_storeId).overrideWith(() => _NoPosts(_storeId)),
        storeReelsProvider(_storeId).overrideWith(() => _NoReels(_storeId)),
        if (chat != null) chatServiceProvider.overrideWithValue(chat),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(api, pushed);
}

void main() {
  testWidgets('visitor, no active story: no ring at all', (tester) async {
    await _pump(tester, ownStore: false);
    final painter = _painter(tester);
    expect(painter.gradient, isFalse);
    expect(painter.color, Colors.transparent);
    expect(find.byIcon(Icons.add), findsNothing, reason: 'not their store');
  });

  testWidgets(
    'own store, no story: no ring, the "+" stays and the avatar opens the add sheet',
    (tester) async {
      await _pump(
        tester,
        ownStore: true,
        rings: [_ring(hasStories: false, seen: false, isOwn: true)],
      );
      final painter = _painter(tester);
      expect(painter.gradient, isFalse);
      expect(painter.color, Colors.transparent);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(_avatarTap);
      await tester.pumpAndSettle();
      expect(find.text(_s.newStory), findsOneWidget, reason: 'add-story sheet');
    },
  );

  testWidgets('an unseen active story draws the gradient ring', (
    tester,
  ) async {
    await _pump(
      tester,
      ownStore: false,
      stories: [_story('s1')],
      rings: [_ring(hasStories: true, seen: false)],
    );
    expect(_painter(tester).gradient, isTrue);
  });

  testWidgets('a fully watched story draws the muted ring', (tester) async {
    await _pump(
      tester,
      ownStore: false,
      stories: [_story('s1')],
      rings: [_ring(hasStories: true, seen: true)],
    );
    final painter = _painter(tester);
    expect(painter.gradient, isFalse);
    expect(painter.color, AppColors.buttonMuted);
  });

  testWidgets('tapping the ringed avatar opens the viewer under /home/story', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      ownStore: false,
      stories: [_story('s1')],
      rings: [_ring(hasStories: true, seen: false)],
    );
    await tester.tap(_avatarTap);
    await tester.pumpAndSettle();

    expect(find.text('viewer'), findsOneWidget);
    final (path, extra) = h.pushed.single;
    expect(path, '/home/story/$_storeId');
    expect(extra, isA<StoryViewerArgs>());
    expect((extra as StoryViewerArgs).storeIds, [_storeId]);
    expect(extra.initialIndex, 0);
  });

  testWidgets('the Message pill reports a failure instead of dying silently', (
    tester,
  ) async {
    // Its onTap awaited a plain POST /chats with no try/catch, so offline the
    // ApiException escaped as an unhandled zone error: the pill did nothing,
    // with no message and no spinner — the exact defect class this pass was
    // commissioned to remove, on the screen under review.
    await _pump(tester, ownStore: false, chat: _OfflineChat());

    Object? escaped;
    final done = Completer<void>();
    runZonedGuarded(() async {
      await tester.tap(find.text(_s.message));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      if (!done.isCompleted) done.complete();
    }, (e, _) {
      escaped ??= e;
      if (!done.isCompleted) done.complete();
    });
    await done.future;

    expect(escaped, isNull, reason: 'must not escape the tap handler');
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(_s.noConnection),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('ApiException'), findsNothing);
  });

  testWidgets('an admin gets the viewer under the admin shell', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      ownStore: true,
      stories: [_story('s1')],
      rings: [_ring(hasStories: true, seen: false, isOwn: true)],
    );
    expect(_painter(tester).gradient, isTrue);
    await tester.tap(_avatarTap);
    await tester.pumpAndSettle();

    expect(find.text('viewer'), findsOneWidget);
    expect(h.pushed.single.$1, '/admin/home/story/$_storeId');
  });
}
