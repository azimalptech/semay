// The in-app banner: what a chat message looks like while the app is OPEN.
// Mounted above the navigator (main.dart wires it into MaterialApp.router's
// builder) so it appears on whatever screen the user is on, and tapping it
// opens that conversation. Whether it is raised at all is decided in
// notification_service.dart by shouldPresentPush — the same rule that used to
// decide the OS notification, not a second copy of it — and that half is
// pinned in test/services/foreground_notification_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:semay/core/l10n.dart';
import 'package:semay/core/router.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/chat/in_app_banner.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/auth_service.dart';

Future<ProviderContainer> _mount(WidgetTester tester) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('some other screen'))),
      ),
      GoRoute(
        path: '/chat/:chatId',
        builder: (context, state) => Scaffold(
          body: Center(child: Text('thread ${state.pathParameters['chatId']}')),
        ),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(const S(false)),
      routerProvider.overrideWithValue(router),
      appRoleProvider.overrideWith((ref) async => AppRole.user),
      userChatsProvider.overrideWith(
        (ref) => Stream.value([
          ChatDoc({'id': 'chatB', 'userId': 'u1', 'storeId': 's1'}),
        ]),
      ),
      storeDocProvider.overrideWith(
        (ref, id) => Stream.value({'id': id, 'name': 'Shop', 'avatarUrl': ''}),
      ),
      userDocProvider.overrideWith((ref, id) async => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => ChatBannerHost(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a message arriving on another screen slides a banner over it', (
    tester,
  ) async {
    final container = await _mount(tester);
    expect(find.text('some other screen'), findsOneWidget);
    expect(container.read(chatBannerProvider), isNull);
    expect(find.text('Shop'), findsNothing, reason: 'nothing showing yet');

    container.read(chatBannerProvider.notifier).show(
      chatId: 'chatB',
      title: 'Shop',
      body: 'Salam, haryt barmy?',
    );
    await tester.pumpAndSettle();

    // Sender and preview, from the push the server already composes.
    expect(find.text('Shop'), findsOneWidget);
    expect(find.text('Salam, haryt barmy?'), findsOneWidget);
    // And their picture — falling back to the initial, since this fixture's
    // store has no avatar.
    expect(find.text('S'), findsOneWidget);
    // Over the screen, not instead of it.
    expect(find.text('some other screen'), findsOneWidget);
  });

  testWidgets('tapping the banner opens that conversation', (tester) async {
    final container = await _mount(tester);
    container.read(chatBannerProvider.notifier).show(
      chatId: 'chatB',
      title: 'Shop',
      body: 'Salam',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Salam'));
    await tester.pumpAndSettle();

    expect(find.text('thread chatB'), findsOneWidget);
    expect(
      container.read(chatBannerProvider),
      isNull,
      reason: 'it goes away once it has done its job',
    );
  });

  testWidgets('it takes itself down after a few seconds', (tester) async {
    final container = await _mount(tester);
    container.read(chatBannerProvider.notifier).show(
      chatId: 'chatB',
      title: 'Shop',
      body: 'Salam',
    );
    await tester.pumpAndSettle();
    expect(find.text('Salam'), findsOneWidget);

    await tester.pump(chatBannerDuration);
    await tester.pumpAndSettle();
    expect(find.text('Salam'), findsNothing);
    expect(container.read(chatBannerProvider), isNull);
  });

  testWidgets('a flick upwards dismisses it', (tester) async {
    final container = await _mount(tester);
    container.read(chatBannerProvider.notifier).show(
      chatId: 'chatB',
      title: 'Shop',
      body: 'Salam',
    );
    await tester.pumpAndSettle();

    await tester.fling(find.text('Salam'), const Offset(0, -80), 800);
    await tester.pumpAndSettle();
    expect(container.read(chatBannerProvider), isNull);
    // Dismissing is not opening.
    expect(find.text('some other screen'), findsOneWidget);
  });
}
