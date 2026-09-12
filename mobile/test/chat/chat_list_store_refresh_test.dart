// activeStoresProvider is a one-shot GET /stores behind a screen that is never
// disposed (a page of the shell pager), so "a store the superadmin activated
// mid-session never appears" had to be fixed with an explicit refresh point.
//
// That point is the pager's own settled-tab signal, NOT this screen's
// VisibilityDetector: the detector samples every 500 ms and drops a sample
// whose visibility matches the previous one, so a fast Chat -> other tab ->
// Chat round trip (a 280 ms animation each way) is invisible to it, and a page
// the PageView builds mid-transit is first reported at a fraction rather than
// at 1.0. It also cannot tell a tab change from a chat thread pushed on top,
// which would turn every thread the user opens and closes into another
// GET /stores.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:semay/core/l10n.dart';
import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/shell_tab.dart';
import 'package:semay/features/chat/chat_list_screen.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/services/auth_service.dart';

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('the store list is re-read when the shell settles back on Chat', (
    tester,
  ) async {
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        l10nProvider.overrideWithValue(const S(false)),
        appRoleProvider.overrideWith((ref) async => AppRole.user),
        realtimeConnectionProvider.overrideWith(
          (ref) => Stream.value(RealtimeConnectionState.connected),
        ),
        userChatsProvider.overrideWith(
          (ref) => Stream.value(const <ChatDoc>[]),
        ),
        activeStoresProvider.overrideWith((ref) async {
          fetches++;
          return const <ChatDoc>[];
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ShellTabScope(index: kChatTabIndex, child: ChatListScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fetches, 1);

    final tab = container.read(settledShellTabProvider.notifier);

    // Arriving on the Chat tab for the first time: the build above already
    // issued the GET, so settling here must not issue a second one.
    tab.set(kChatTabIndex);
    await tester.pumpAndSettle();
    expect(fetches, 1, reason: 'no double fetch on the first arrival');

    // Away to another tab and back — the refresh point.
    tab.set(0);
    await tester.pumpAndSettle();
    tab.set(kChatTabIndex);
    await tester.pumpAndSettle();
    expect(fetches, 2, reason: 'coming back to the Chat tab re-reads /stores');

    // A chat thread (or any page route) pushed over the shell publishes null
    // and then the same tab again. That is not a tab change and must not cost
    // a request — the user taps in and out of threads constantly.
    tab.set(null);
    await tester.pumpAndSettle();
    tab.set(kChatTabIndex);
    await tester.pumpAndSettle();
    expect(
      fetches,
      2,
      reason: 'opening a thread and popping back is not a tab change',
    );

    // A second round trip still refreshes.
    tab.set(1);
    await tester.pumpAndSettle();
    tab.set(kChatTabIndex);
    await tester.pumpAndSettle();
    expect(fetches, 3);
  });
}
