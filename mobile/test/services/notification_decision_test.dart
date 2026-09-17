// The one rule for chat-push presentation, stated once in code
// (shouldPresentPush) and applied on Android by the app's own foreground
// notification and on iOS by AppDelegate.swift's willPresent override: a chat
// push is silent ONLY when its chatId equals the thread on screen with the app
// resumed; everything else plays the message sound; broadcasts never suppressed.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/services/notification_service.dart';

void main() {
  test('a message for the thread on screen is silent', () {
    expect(shouldPresentPush(chatId: 'A', activeChatId: 'A'), isFalse);
  });

  test('a message for another thread while inside a thread is presented', () {
    expect(shouldPresentPush(chatId: 'B', activeChatId: 'A'), isTrue);
  });

  test(
    'a message while no thread is open (list, inbox, other tab, paused) is presented',
    () {
      expect(shouldPresentPush(chatId: 'A', activeChatId: null), isTrue);
    },
  );

  test('a broadcast (no chatId) is never suppressed, even inside a thread', () {
    expect(shouldPresentPush(chatId: null, activeChatId: 'A'), isTrue);
  });

  test('a push with no chatId while no thread is open is presented', () {
    expect(shouldPresentPush(chatId: null, activeChatId: null), isTrue);
  });
}
