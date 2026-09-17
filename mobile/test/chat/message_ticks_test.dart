// What a sender is told about their own message. This file used to pin the
// WhatsApp-style per-bubble tick model — one grey check for sent, double grey
// for delivered, double blue for read — and now pins what replaced it:
// Instagram's ONE status line under the newest message, Sending… → Sent →
// Seen, with a relative time, and no delivered step anywhere in the UI.
//
// The server still records delivery and still publishes it; it just never
// reaches the user's eyes (unread counters and the badge are what it feeds).
// See MessageStatusLine's doc comment.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/app_icon.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/features/chat/chat_thread_screen.dart';

const _tk = S(false);
const _ru = S(true);

Future<void> _pump(
  WidgetTester tester,
  MessageStatusLine line, {
  S s = _tk,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [l10nProvider.overrideWithValue(s)],
      child: MaterialApp(home: Scaffold(body: Center(child: line))),
    ),
  );
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byType(MessageStatusLine),
        matching: find.byType(Text),
      ),
    )
    .data!;

void main() {
  final now = DateTime(2026, 9, 16, 10, 30);

  // The model itself: three states, and no fourth one for "delivered".
  test('there is no delivered state to show', () {
    expect(
      MessageSendState.values.map((v) => v.name),
      ['sending', 'sent', 'seen'],
    );
  });

  testWidgets('sending: the label says so and carries no time', (tester) async {
    await _pump(
      tester,
      MessageStatusLine(
        state: MessageSendState.sending,
        at: now.subtract(const Duration(minutes: 3)),
        now: now,
      ),
    );
    expect(_text(tester), _tk.sendingStatus);
    // Never a tick glyph — that whole vocabulary is gone.
    expect(find.byType(AppIcon), findsNothing);
  });

  testWidgets('sent: the send time, relative', (tester) async {
    await _pump(
      tester,
      MessageStatusLine(
        state: MessageSendState.sent,
        at: now.subtract(const Duration(minutes: 3)),
        now: now,
      ),
    );
    expect(_text(tester), _tk.sentAgo('3 min öň'));
    expect(_text(tester), contains('3 min öň'));
  });

  testWidgets('seen: the READ time, not the send time', (tester) async {
    // The caller passes readAt as `at` for this state (chat_thread_screen.dart
    // builds it as `readAt ?? timestamp`), so "Seen 1 min ago" is about when
    // they opened the thread, not when it was sent an hour earlier.
    await _pump(
      tester,
      MessageStatusLine(
        state: MessageSendState.seen,
        at: now.subtract(const Duration(minutes: 1)),
        now: now,
      ),
    );
    expect(_text(tester), _tk.seenAgo('1 min öň'));
  });

  testWidgets('the relative time ages without a new message', (tester) async {
    // The thread re-renders every second off its staleness ticker, handing in
    // a fresh `now` — which is the whole mechanism, so no second timer exists
    // and none is needed.
    final sentAt = now.subtract(const Duration(minutes: 1));
    await _pump(
      tester,
      MessageStatusLine(state: MessageSendState.sent, at: sentAt, now: now),
    );
    expect(_text(tester), _tk.sentAgo('1 min öň'));

    await _pump(
      tester,
      MessageStatusLine(
        state: MessageSendState.sent,
        at: sentAt,
        now: now.add(const Duration(hours: 2)),
      ),
    );
    expect(_text(tester), _tk.sentAgo('2 sag öň'));
  });

  testWidgets('a just-sent message reads as "now", never a negative age', (
    tester,
  ) async {
    // Clock skew between the server's createdAt and the phone can put `at`
    // slightly in the future; "-1 min öň" would be nonsense.
    await _pump(
      tester,
      MessageStatusLine(
        state: MessageSendState.sent,
        at: now.add(const Duration(seconds: 5)),
        now: now,
      ),
    );
    expect(_text(tester), _tk.sentAgo('häzir'));
  });

  // tk is the default and ru is the only other language; there is no English
  // in this product (core/l10n.dart).
  testWidgets('every new string exists in both languages, and differs', (
    tester,
  ) async {
    await _pump(
      tester,
      MessageStatusLine(
        state: MessageSendState.seen,
        at: now.subtract(const Duration(days: 2)),
        now: now,
      ),
      s: _ru,
    );
    expect(_text(tester), _ru.seenAgo('2 дн назад'));

    for (final pair in [
      [_tk.sendingStatus, _ru.sendingStatus],
      [_tk.sentAgo('x'), _ru.sentAgo('x')],
      [_tk.seenAgo('x'), _ru.seenAgo('x')],
      [_tk.messageNotSentTitle, _ru.messageNotSentTitle],
      [_tk.retrySend, _ru.retrySend],
      [_tk.deleteMessage, _ru.deleteMessage],
      [_tk.timeAgo(const Duration(minutes: 5)), _ru.timeAgo(const Duration(minutes: 5))],
    ]) {
      expect(pair[0], isNotEmpty);
      expect(pair[1], isNotEmpty);
      expect(pair[0], isNot(pair[1]));
    }
  });
}
