// The three states a sender can tell apart under their own bubble — sent,
// delivered, read — plus the outbox's pending and failed marks. Each pair
// must differ in glyph or colour; "read" in particular used to be brand
// purple, which next to the grey delivered tick did not register as a
// different state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/app_icon.dart';
import 'package:semay/core/theme.dart';
import 'package:semay/features/chat/chat_thread_screen.dart';

Future<void> _pump(WidgetTester tester, MessageStatusTicks ticks) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: ticks))));
  await tester.pumpAndSettle();
}

AppIcon _icon(WidgetTester tester) => tester.widget<AppIcon>(
  find.descendant(of: find.byType(MessageStatusTicks), matching: find.byType(AppIcon)),
);

void main() {
  final at = DateTime(2026, 9, 16, 10, 30);

  testWidgets('sent: a single grey check', (tester) async {
    await _pump(tester, const MessageStatusTicks(deliveredAt: null, readAt: null));
    final icon = _icon(tester);
    expect(icon.name, 'check');
    expect(icon.color, AppColors.textSecondary);
  });

  testWidgets('delivered: a double grey check', (tester) async {
    await _pump(tester, MessageStatusTicks(deliveredAt: at, readAt: null));
    final icon = _icon(tester);
    expect(icon.name, 'check_double');
    expect(icon.color, AppColors.textSecondary);
  });

  testWidgets('read: a double blue check, even when the delivered stamp never came', (
    tester,
  ) async {
    // A read receipt implies delivery; a message can be read before the
    // list-level delivered receipt reached this device.
    await _pump(tester, MessageStatusTicks(deliveredAt: null, readAt: at));
    final icon = _icon(tester);
    expect(icon.name, 'check_double');
    expect(icon.color, AppColors.readTick);
    expect(AppColors.readTick, isNot(AppColors.textSecondary));
    expect(AppColors.readTick, isNot(AppColors.brand));
  });

  testWidgets('pending and failed use their own marks', (tester) async {
    await _pump(tester, const MessageStatusTicks(deliveredAt: null, readAt: null, isPending: true));
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byType(AppIcon), findsNothing);

    await _pump(
      tester,
      const MessageStatusTicks(deliveredAt: null, readAt: null, isPending: true, isFailed: true),
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsNothing);
  });
}
