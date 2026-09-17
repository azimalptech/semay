// The bottom-nav Chat badge is the one place a plain user sees unread
// without opening the list. It is fed by totalUnreadChatCountProvider, which
// picks the list for the role — the user's own conversations, or every
// store's for an admin — so these pin: the right list for each role, the sum
// across chats, nothing drawn at zero, and a live update when a chat's
// count changes over the socket.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/router.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/services/auth_service.dart';

ChatDoc _chat(String id, {int unreadByUser = 0, int unreadByAdmin = 0}) => ChatDoc({
  'id': id,
  'storeId': 's1',
  'userId': 'u1',
  'unreadByUser': unreadByUser,
  'unreadByAdmin': unreadByAdmin,
  'lastMessageAt': '2026-09-16T08:00:00.000Z',
});

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required AppRole role,
  required Stream<List<ChatDoc>> userChats,
  required Stream<List<ChatDoc>> adminChats,
}) async {
  final container = ProviderContainer(
    overrides: [
      appRoleProvider.overrideWith((ref) async => role),
      userChatsProvider.overrideWith((ref) => userChats),
      adminChatsProvider.overrideWith((ref) => adminChats),
    ],
  );
  addTearDown(container.dispose);
  final controller = PageController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          bottomNavigationBar: TabNavBar(
            controller: controller,
            settledIndex: 0,
            onTap: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a plain user sees the sum of unreadByUser across their chats', (tester) async {
    await _pump(
      tester,
      role: AppRole.user,
      userChats: Stream.value([
        _chat('c1', unreadByUser: 3, unreadByAdmin: 9),
        _chat('c2', unreadByUser: 2),
        _chat('c3'),
      ]),
      // Not this user's list — must not leak into their badge.
      adminChats: Stream.value([_chat('x', unreadByAdmin: 7)]),
    );
    expect(find.text('5'), findsOneWidget);
    expect(find.text('7'), findsNothing);
    expect(find.text('9'), findsNothing);
  });

  testWidgets('nothing is drawn at zero', (tester) async {
    await _pump(
      tester,
      role: AppRole.user,
      userChats: Stream.value([_chat('c1'), _chat('c2')]),
      adminChats: Stream.value(const []),
    );
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a store admin sees unreadByAdmin across every store', (tester) async {
    await _pump(
      tester,
      role: AppRole.admin,
      userChats: Stream.value([_chat('c1', unreadByUser: 5)]),
      adminChats: Stream.value([
        _chat('a1', unreadByAdmin: 4),
        _chat('a2', unreadByAdmin: 3),
      ]),
    );
    expect(find.text('7'), findsOneWidget);
    expect(find.text('5'), findsNothing);
  });

  testWidgets('the badge follows the list live', (tester) async {
    final userChats = StreamController<List<ChatDoc>>();
    addTearDown(userChats.close);
    await _pump(
      tester,
      role: AppRole.user,
      userChats: userChats.stream,
      adminChats: Stream.value(const []),
    );
    userChats.add([_chat('c1', unreadByUser: 1)]);
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    // A message lands over the socket: the row's count rises.
    userChats.add([_chat('c1', unreadByUser: 2), _chat('c2', unreadByUser: 1)]);
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);

    // The thread was opened: its receipt zeroed the count.
    userChats.add([_chat('c1'), _chat('c2')]);
    await tester.pumpAndSettle();
    expect(find.text('3'), findsNothing);
    expect(find.text('0'), findsNothing);
  });
}
