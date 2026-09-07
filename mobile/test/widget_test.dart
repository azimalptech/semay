// Phase 1 smoke test — confirms the phone-entry screen renders without
// needing Firebase/Riverpod setup (it only calls sendOtp on submit).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/l10n.dart';
import 'package:semay/features/auth/phone_entry_screen.dart';

void main() {
  testWidgets('PhoneEntryScreen renders phone input', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: PhoneEntryScreen()),
      ),
    );

    // The product ships tk/ru only (no English); with no profile loaded the
    // l10nProvider falls back to Turkmen, so assert the copy that renders.
    expect(find.text(const S(false).enterPhoneToStart), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
