// Share links (docs/04 "Share links"): the OS hands the app
// https://semaycollection.com/p/<id> — the initial route on a cold start,
// pushRouteInformation on a warm one — or semay://open/s/<id> from the share
// page's button. router.dart must never rest on those paths: the linked
// screen is pushed OVER the shell once the normal gates (splash, login) have
// landed there, so back returns to the shell instead of leaving the app.
// These drive the real routerProvider with every network-backed provider
// stubbed; nothing here reaches the API or the socket.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/router.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/auth/phone_entry_screen.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/feed/feed_providers.dart';
import 'package:semay/features/feed/feed_screen.dart';
import 'package:semay/features/profile/notifications_providers.dart';
import 'package:semay/features/shared/post_detail_screen.dart';
import 'package:semay/features/shared/post_interaction_providers.dart';
import 'package:semay/features/shared/story_bar_provider.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/features/store_profile/store_profile_screen.dart';
import 'package:semay/features/story_viewer/story_providers.dart';
import 'package:semay/services/auth_service.dart';

const _postId = '288fcd06-2cad-4399-9b11-88a9365ad3a0';
const _storeId = 'e8fa0956-2dc3-4234-9445-4428a5bf2f76';

SessionClaims _claimsFor(String role) => SessionClaims(
  uid: 'u1',
  role: role,
  storeIds: role == 'admin' ? const [_storeId] : const [],
  claimsVersion: 0,
);

/// The persisted session as the router sees it — starts signed in or out,
/// and can sign in later (the "cold start on a link while logged out" case).
class _FakeSession extends SessionController {
  _FakeSession({required this.signedIn, this.role = 'user'});

  final bool signedIn;
  final String role;

  @override
  Future<SessionClaims?> build() async => signedIn ? _claimsFor(role) : null;

  void signIn() => state = AsyncData(_claimsFor(role));
}

class _EmptyFeed extends FeedNotifier {
  @override
  Future<List<PostDoc>> build() async {
    hasMore = false;
    return const [];
  }

  @override
  Future<void> loadMore() async {}
}

class _EmptyStorePosts extends StorePostsNotifier {
  _EmptyStorePosts(super.storeId);

  @override
  Future<List<PostDoc>> build() async {
    hasMore = false;
    return const [];
  }

  @override
  Future<void> loadMore() async {}
}

class _EmptyStoreReels extends StoreReelsNotifier {
  _EmptyStoreReels(super.storeId);

  @override
  Future<List<PostDoc>> build() async {
    hasMore = false;
    return const [];
  }

  @override
  Future<void> loadMore() async {}
}

/// The detail screen's view dwell records a view after 0.8 s; the real
/// buffer would open SQLite for it.
class _NoopBuffer extends InteractionBuffer {
  _NoopBuffer() : super(ApiClient(Dio()));

  @override
  Future<void> record(String postId, InteractionKind kind) async {}
}

Map<String, dynamic> _post(String id) => {
  'id': id,
  'storeId': _storeId,
  'type': 'image',
  'caption': 'Täze köýnek',
  'thumbnailUrl': '',
  'mediaUrls': <String>[],
  'createdAt': '2026-09-07T10:00:00.000Z',
  'likesCount': 0,
  'viewsCount': 0,
  'sentCount': 0,
  'sharesCount': 0,
  'likedByMe': false,
  'savedByMe': false,
};

Map<String, dynamic> _store(String id) => {
  'id': id,
  'name': 'Aýna',
  'avatarUrl': '',
  'tagline': '',
  'phone': '',
  'address': '',
  'postsCount': 0,
  'reelsCount': 0,
  'likesCount': 0,
};

class _Harness {
  _Harness(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;
  late final GoRouter router;

  _FakeSession get session =>
      container.read(sessionControllerProvider.notifier) as _FakeSession;

  /// The navigation stack as matched locations, bottom first.
  List<String> get stack => [
    for (final m in router.routerDelegate.currentConfiguration.matches)
      m.matchedLocation,
  ];

  /// Not pumpAndSettle: the Home tab's story ring spins for as long as the
  /// shell is the top route, so "no frame scheduled" never comes there. A
  /// fixed 1.2 s covers the 300 ms route transition plus the microtask that
  /// pushes a parked link.
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Cold start. [initialRoute] is what the engine reports as the platform's
  /// default route — the full URI of the link the app was opened with, or
  /// '/' for a plain launch (go_router only consults it when it isn't '/').
  Future<void> launch({String initialRoute = '/'}) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = initialRoute;
    router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await settle();
  }

  /// A link arriving while the app is already running — what the Android
  /// embedding's onNewIntent / iOS openURL deliver over the navigation
  /// channel (Router -> go_router -> redirect).
  Future<void> openLink(String link) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        MethodCall('pushRouteInformation', {'location': link, 'state': null}),
      ),
      (_) {},
    );
    await settle();
  }

  /// Let the detail screen's 0.8 s view dwell fire and dispose the tree so
  /// no timer outlives the test.
  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  }
}

void _routerTest(
  String description, {
  required bool signedIn,
  String role = 'user',
  required Future<void> Function(_Harness h) body,
}) {
  testWidgets(description, (tester) async {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        sessionControllerProvider.overrideWith(
          () => _FakeSession(signedIn: signedIn, role: role),
        ),
        userProfileProvider.overrideWith((ref) async {
          final session = await ref.watch(authStateChangesProvider.future);
          return session == null ? null : {'name': 'Test', 'language': 'tk'};
        }),
        // The Home tab, which the shell builds first.
        feedNotifierProvider.overrideWith(_EmptyFeed.new),
        storyBarProvider.overrideWith(
          (ref) async => [
            StoryRingInfo(
              storeId: _storeId,
              storeName: 'Aýna',
              avatarUrl: '',
              hasStories: true,
              seen: true,
              isOwn: false,
            ),
          ],
        ),
        unreadNotificationCountProvider.overrideWithValue(0),
        userChatsProvider.overrideWith(
          (ref) => Stream.value(const <ChatDoc>[]),
        ),
        // The linked screens.
        postDocProvider.overrideWith((ref, id) => Stream.value(_post(id))),
        storeSummaryProvider.overrideWith(
          (ref, id) => Stream.value(_store(id)),
        ),
        storeDocProvider.overrideWith((ref, id) => Stream.value(_store(id))),
        storeStoriesProvider.overrideWith((ref, id) async => const []),
        storePostsProvider.overrideWith2(_EmptyStorePosts.new),
        storeReelsProvider.overrideWith2(_EmptyStoreReels.new),
        pendingInteractionsProvider.overrideWith(
          (ref, id) => Stream.value((views: 0, sent: 0, shares: 0)),
        ),
        interactionBufferProvider.overrideWith((ref) => _NoopBuffer()),
      ],
    );
    addTearDown(container.dispose);
    final h = _Harness(tester, container);
    await body(h);
    await h.finish();
  });
}

void main() {
  _routerTest(
    'cold start on https://semaycollection.com/p/<id> lands on the post, '
    'over the shell',
    signedIn: true,
    body: (h) async {
      await h.launch(initialRoute: 'https://semaycollection.com/p/$_postId');

      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(find.text('Täze köýnek'), findsOneWidget);
      expect(h.stack, ['/home', '/post/$_postId']);
      // The shell is underneath, not replaced — back returns to it.
      expect(find.byType(FeedScreen, skipOffstage: false), findsOneWidget);

      h.router.pop();
      await h.settle();
      expect(find.byType(PostDetailScreen), findsNothing);
      expect(h.stack, ['/home']);
      expect(find.byType(FeedScreen), findsOneWidget);
    },
  );

  _routerTest(
    'a reel link (/r/) opens the same detail screen',
    signedIn: true,
    body: (h) async {
      await h.launch(initialRoute: 'https://www.semaycollection.com/r/$_postId');
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(h.stack, ['/home', '/post/$_postId']);
    },
  );

  _routerTest(
    'warm start: semay://open/s/<id> opens the store profile over the shell, '
    'and the legacy semay://post/<id> still opens the post',
    signedIn: true,
    body: (h) async {
      await h.launch();
      expect(h.stack, ['/home']);
      expect(find.byType(StoreProfileScreen), findsNothing);

      await h.openLink('semay://open/s/$_storeId');
      expect(find.byType(StoreProfileScreen), findsOneWidget);
      expect(find.text('Aýna'), findsWidgets);
      expect(h.stack, ['/home', '/store/$_storeId']);

      h.router.pop();
      await h.settle();
      expect(h.stack, ['/home']);

      await h.openLink('semay://post/$_postId');
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(h.stack, ['/home', '/post/$_postId']);

      // Nothing left parked: a later plain navigation must not re-open it.
      h.router.pop();
      await h.settle();
      h.router.push('/search');
      await h.settle();
      expect(find.byType(PostDetailScreen), findsNothing);
      expect(h.stack, ['/home', '/search']);
    },
  );

  _routerTest(
    'a warm link pushes over the CURRENT stack instead of resetting it',
    signedIn: true,
    body: (h) async {
      await h.launch();
      h.router.push('/search');
      await h.settle();
      h.router.push('/store/$_storeId');
      await h.settle();
      expect(h.stack, ['/home', '/search', '/store/$_storeId']);

      // The platform delivers the link while those three screens are live —
      // the user tapped a SeMay link in another app. go_router's own
      // handling would answer with setNewRoutePath, which REPLACES the whole
      // configuration and silently discards /search and the store profile.
      await h.openLink('https://semaycollection.com/p/$_postId');

      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(h.stack, ['/home', '/search', '/store/$_storeId', '/post/$_postId']);

      // …and back returns to exactly where the user was, as it does in
      // WhatsApp and Instagram.
      h.router.pop();
      await h.settle();
      expect(h.stack, ['/home', '/search', '/store/$_storeId']);
      expect(find.byType(StoreProfileScreen), findsOneWidget);
    },
  );

  _routerTest(
    'an admin cold-starting on a link lands on the post over the ADMIN shell',
    signedIn: true,
    role: 'admin',
    body: (h) async {
      await h.launch(initialRoute: 'https://semaycollection.com/p/$_postId');

      // The deep-link parking helper and the role gate must agree about what
      // "admin" means — they used to test the role two different ways.
      expect(h.stack, ['/admin/home', '/post/$_postId']);
      expect(find.byType(PostDetailScreen), findsOneWidget);

      h.router.pop();
      await h.settle();
      expect(h.stack, ['/admin/home']);
    },
  );

  _routerTest(
    'cold start on a link while logged out: login first, then the post',
    signedIn: false,
    body: (h) async {
      await h.launch(initialRoute: 'https://semaycollection.com/p/$_postId');

      // Parked behind the login gate — not lost, not shown.
      expect(find.byType(PhoneEntryScreen), findsOneWidget);
      expect(find.byType(PostDetailScreen), findsNothing);
      expect(h.stack, ['/auth/phone']);

      h.session.signIn();
      await h.settle();

      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(h.stack, ['/home', '/post/$_postId']);

      h.router.pop();
      await h.settle();
      expect(h.stack, ['/home']);
    },
  );

  // ---------------------------------------------------------------------
  // Links the app CLAIMS from the OS but cannot parse. The AndroidManifest
  // autoVerify filter claims every https://semaycollection.com path merely
  // STARTING with /p/, /r/ or /s/, and the custom-scheme filter claims
  // semay:// with no path constraint at all — a far wider space than
  // parseIncomingLink accepts. Once App Links verify, Android routes all of
  // it to the app with no chooser, so a truncated, mangled or
  // punctuation-suffixed link a friend forwards arrives here. It must never
  // be a resting place: go_router answers an unmatched location with its
  // default "Page Not Found" screen over an EMPTY stack, with no AppBar, no
  // back and no shell — on Android the only way out is to kill the app.

  _routerTest(
    'a claimed-but-unparseable link cold-starts on the shell, not "Page Not Found"',
    signedIn: true,
    body: (h) async {
      // "/p/" alone: exactly what the manifest pathPrefix claims, and what a
      // truncated paste produces.
      await h.launch(initialRoute: 'https://semaycollection.com/p/');

      expect(h.stack, ['/home']);
      expect(find.text('Page Not Found'), findsNothing);
      expect(find.byType(FeedScreen), findsOneWidget);
    },
  );

  _routerTest(
    'a claimed-but-unparseable warm link is a no-op and leaves the stack intact',
    signedIn: true,
    body: (h) async {
      await h.launch();
      h.router.push('/search');
      await h.settle();
      h.router.push('/store/$_storeId');
      await h.settle();
      const before = ['/home', '/search', '/store/$_storeId'];
      expect(h.stack, before);

      // Trailing prose punctuation, an extra segment, a non-UUID id, and the
      // scheme filter's unconstrained space. Every one is delivered to the
      // app by the OS and returns null from the parser; letting any of them
      // fall through to go_router is what destroys the stack.
      for (final link in [
        'https://semaycollection.com/p/$_postId/extra',
        'https://semaycollection.com/p/$_postId.',
        'https://semaycollection.com/p/abc123',
        'https://semaycollection.com/s/',
        'semay://open/x/$_postId',
      ]) {
        await h.openLink(link);
        expect(h.stack, before, reason: link);
        expect(find.text('Page Not Found'), findsNothing, reason: link);
      }
      expect(find.byType(StoreProfileScreen), findsOneWidget);
    },
  );

  _routerTest(
    'a foreign host is still handed back to go_router, not swallowed',
    signedIn: true,
    body: (h) async {
      // The no-op above must be scoped to URIs the app actually claims. A
      // route that is not ours has to keep falling through, or an in-app
      // route pushed over the platform channel would stop working.
      await h.launch();
      await h.openLink('/search');
      expect(h.stack, ['/search']);
    },
  );
}
