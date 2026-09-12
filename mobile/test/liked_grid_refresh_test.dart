// The Liked/Saved grid's doc comment has claimed "REST + pull-to-refresh"
// since the migration, but there was no RefreshIndicator anywhere in it — the
// list was whatever the one-shot provider had fetched at app start. This pins
// the gesture: a pull really does re-read the ids.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/l10n.dart';
import 'package:semay/features/profile/liked_screen.dart';
import 'package:semay/features/profile/profile_providers.dart';
import 'package:semay/features/shared/post_interaction_providers.dart';

void main() {
  testWidgets('pulling the liked grid refetches the ids', (tester) async {
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        l10nProvider.overrideWithValue(const S(false)),
        likedPostIdsProvider.overrideWith((ref) async {
          fetches++;
          return ['post-1'];
        }),
        // No media urls: the tile paints its placeholder box and never starts
        // an image fetch.
        postDocProvider.overrideWith(
          (ref, id) => Stream<Map<String, dynamic>?>.value({
            'id': id,
            'type': 'image',
            'thumbnailUrl': '',
            'mediaUrls': const <String>[],
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PostIdGrid(kind: PostGridKind.liked)),
      ),
    );
    await tester.pumpAndSettle();
    expect(fetches, 1);
    expect(find.byType(GridView), findsOneWidget);

    await tester.fling(find.byType(GridView), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(fetches, 2, reason: 'the pull must re-read /users/me/liked');
  });

  testWidgets('a refetch that fails keeps the grid the user is looking at', (
    tester,
  ) async {
    // The provider refetches on its own now (400 ms after the outbox reports
    // a like landing), so a transient GET failure can arrive with no user
    // gesture at all. `.when` sends an AsyncError to `error` even when the
    // previous list is still in `.value`, which replaced a correct grid with
    // an error page — the fix is `skipError: true`, and this pins it.
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        l10nProvider.overrideWithValue(const S(false)),
        likedPostIdsProvider.overrideWith((ref) async {
          if (fetches++ == 0) return ['post-1'];
          throw StateError('transient 5xx');
        }),
        postDocProvider.overrideWith(
          (ref, id) => Stream<Map<String, dynamic>?>.value({
            'id': id,
            'type': 'image',
            'thumbnailUrl': '',
            'mediaUrls': const <String>[],
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PostIdGrid(kind: PostGridKind.liked)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);

    // Exactly what refetchWhenOutboxSends' debounce timer does.
    container.invalidate(likedPostIdsProvider);
    await tester.pumpAndSettle();

    expect(fetches, 2);
    expect(
      find.byType(GridView),
      findsOneWidget,
      reason: 'a failed background refetch must not wipe the painted grid',
    );
    expect(find.textContaining('transient 5xx'), findsNothing);
  });

  testWidgets('a first load that fails still reports the error', (
    tester,
  ) async {
    // skipError only skips when there IS a previous value — a cold failure
    // must still say so rather than showing an empty grid forever.
    final container = ProviderContainer(
      overrides: [
        l10nProvider.overrideWithValue(const S(false)),
        likedPostIdsProvider.overrideWith(
          (ref) async => throw StateError('cold boom'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PostIdGrid(kind: PostGridKind.liked)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('cold boom'), findsOneWidget);
  });

  testWidgets('leaving the saved grid and coming back refetches', (
    tester,
  ) async {
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        l10nProvider.overrideWithValue(const S(false)),
        savedPostIdsProvider.overrideWith((ref) async {
          fetches++;
          return const <String>[];
        }),
      ],
    );
    addTearDown(container.dispose);

    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );

    Future<void> openGrid() async {
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const PostIdGrid(kind: PostGridKind.saved),
        ),
      );
      await tester.pumpAndSettle();
    }

    await openGrid();
    expect(fetches, 1);

    // Popping must dispose it (the provider is autoDispose now) — otherwise
    // this second open serves the list from the first one forever, which is
    // the whole bug.
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    await openGrid();

    expect(fetches, 2, reason: 're-entering the screen must re-read the ids');
  });
}
