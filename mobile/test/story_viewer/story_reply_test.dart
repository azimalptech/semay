// The store-profile ring now opens this viewer, and its reply box was the one
// action in it still on the old shape: `try { … } finally { … }` with no
// catch. The first call inside it, createOrGetChat, is a plain POST /chats —
// NOT the outbox path — so offline it threw straight out of the async
// onPressed as an unhandled zone error: the send button did nothing at all,
// the text stayed put, and nothing was said.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/feed/feed_providers.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/features/story_viewer/story_providers.dart';
import 'package:semay/features/story_viewer/story_viewer_screen.dart';
import 'package:semay/services/chat_service.dart';

import '../support/fakes.dart';

const _storeId = 'store-1';
const _s = S(false);

final _store = <String, dynamic>{
  'id': _storeId,
  'name': 'Audit Store',
  'avatarUrl': '',
};

PostDoc _story() => PostDoc({
  'id': 's1',
  'storeId': _storeId,
  // Deliberately unreachable: the precache fails in a widget test, which the
  // viewer now swallows instead of raising an unhandled async error.
  'mediaUrl': 'http://127.0.0.1:1/media/stories/s1.jpg',
  'mediaType': 'image',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'expiresAt': DateTime.now()
      .add(const Duration(hours: 23))
      .toUtc()
      .toIso8601String(),
});

/// A ChatService whose very first call fails, the way a dead network makes it.
class _OfflineChat implements ChatService {
  @override
  Future<String> createOrGetChat(String storeId) async =>
      throw ApiException(null, 'REQUEST_FAILED');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  testWidgets('a reply that cannot reach the server says so, and nothing escapes', (
    tester,
  ) async {
    final api = FakeApi()..onGet = (_) => const {};
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionControllerProvider.overrideWith(() => FakeSession()),
          storeDocProvider(_storeId).overrideWith((ref) => Stream.value(_store)),
          storeStoriesProvider(_storeId).overrideWith((ref) async => [_story()]),
          chatServiceProvider.overrideWithValue(_OfflineChat()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StoryViewerScreen(storeId: _storeId)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final field = find.byType(TextField);
    expect(field, findsOneWidget, reason: 'the visitor reply box');
    await tester.enterText(field, 'Salam');
    await tester.pump();

    Object? escaped;
    final done = Completer<void>();
    runZonedGuarded(() async {
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      if (!done.isCompleted) done.complete();
    }, (e, _) {
      escaped ??= e;
      if (!done.isCompleted) done.complete();
    });
    await done.future;

    expect(escaped, isNull, reason: 'the failure must not escape the onPressed');
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(_s.noConnection),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('ApiException'), findsNothing);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Salam',
      reason: 'the reply is kept so it can be sent again',
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton).last).onPressed,
      isNotNull,
      reason: 'the send button is live again',
    );
  });
}
