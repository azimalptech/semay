// Phase 1 smoke test — confirms the phone-entry screen renders without
// needing Firebase/Riverpod setup (it only calls sendOtp on submit).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/features/auth/phone_entry_screen.dart';

void main() {
  testWidgets('PhoneEntryScreen renders phone input', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: PhoneEntryScreen()),
      ),
    );

    expect(find.textContaining('phone number'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
