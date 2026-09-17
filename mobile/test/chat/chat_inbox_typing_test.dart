// "Typing…" in the INBOX, under their name — the half of the typing indicator
// SeMay never had. The chat row already carries typingUserAt/typingAdminAt and
// the chat-list channel already delivers whole chat rows; what was missing was
// (a) the server republishing the row to the list channels when the stamp
// changes (chats/service.ts setTyping now uses publishChatEverywhere) and
// (b) this: the row showing it.
//
// Expiry is the row's own job — nothing arrives to say "they stopped" — and is
// done per row on a one-shot timer, not by ticking the whole list every second.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:semay/core/l10n.dart';
import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/shell_tab.dart';
import 'package:semay/features/chat/chat_list_screen.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/auth_service.dart';

const _s = S(false);

ChatDoc _chat({required DateTime? adminTypingAt}) => ChatDoc({
  'id': 'u1_s1',
  'userId': 'u1',
  'storeId': 's1',
  'lastMessageText': 'öňki habar',
  'lastMessageAt': DateTime.now().toUtc().toIso8601String(),
  'unreadByUser': 0,
  'unreadByAdmin': 0,
  'typingAdminAt': adminTypingAt?.toUtc().toIso8601String(),
  'typingUserAt': null,
});

Future<ProviderContainer> _mount(WidgetTester tester, ChatDoc chat) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(_s),
      appRoleProvider.overrideWith((ref) async => AppRole.user),
      realtimeConnectionProvider.overrideWith(
        (ref) => Stream.value(RealtimeConnectionState.connected),
      ),
      userChatsProvider.overrideWith((ref) => Stream.value([chat])),
      activeStoresProvider.overrideWith((ref) async => const <ChatDoc>[]),
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
      child: const MaterialApp(
        home: ShellTabScope(index: kChatTabIndex, child: ChatListScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a fresh typing stamp replaces the last message with "typing…"', (
    tester,
  ) async {
    await _mount(tester, _chat(adminTypingAt: DateTime.now()));

    expect(find.text(_s.typing), findsOneWidget);
    expect(
      find.text('öňki habar'),
      findsNothing,
      reason: 'typing takes the subtitle line while it lasts',
    );
    // Still their row, still tappable — only the second line changed.
    expect(find.text('Shop'), findsOneWidget);
  });

  testWidgets('a stale stamp shows the last message, as before', (tester) async {
    await _mount(
      tester,
      _chat(
        adminTypingAt: DateTime.now().subtract(
          typingFreshness + const Duration(seconds: 1),
        ),
      ),
    );

    expect(find.text(_s.typing), findsNothing);
    expect(find.text('öňki habar'), findsOneWidget);
  });

  testWidgets('no stamp at all: nothing changes', (tester) async {
    await _mount(tester, _chat(adminTypingAt: null));

    expect(find.text(_s.typing), findsNothing);
    expect(find.text('öňki habar'), findsOneWidget);
  });

  // Pull-to-refresh lives on the inbox only. Inside a conversation the list is
  // reversed, so a downward pull lands at the bottom, and an upward pull is
  // already how older messages page in.
  testWidgets('the inbox can be pulled to refresh, and re-reads the list', (
    tester,
  ) async {
    final container = await _mount(tester, _chat(adminTypingAt: null));
    addTearDown(container.dispose);

    expect(find.byType(RefreshIndicator), findsOneWidget);

    await tester.fling(find.byType(RefreshIndicator), const Offset(0, 320), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: 'the pull must actually start a refresh, not just scroll',
    );

    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
