// parseTimestamp is the single seam between the API's UTC wire format and
// every `.hour`/`.day` read in the UI, so these pin both halves of its
// contract: a `Z` string becomes device-local wall-clock time at the same
// instant, and anything that never carried a zone (the outbox's naive
// strings, garbage) keeps the DateTime.tryParse behaviour callers rely on.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/json_ext.dart';

void main() {
  group('parseTimestamp', () {
    const wire = '2026-09-07T17:46:43.946Z';
    final instant = DateTime.utc(2026, 9, 7, 17, 46, 43, 946);

    test('a Z string becomes local time at the same instant', () {
      final parsed = parseTimestamp(wire)!;
      expect(parsed.isUtc, isFalse);
      expect(parsed.millisecondsSinceEpoch, instant.millisecondsSinceEpoch);
      expect(parsed, instant.toLocal());
      // .hour/.minute must read as the device's wall clock whatever zone the
      // test host is in (17:46 shifted by the offset, wrapped) — never the
      // raw UTC 17:46 the bug showed.
      final minutesOfDay =
          (17 * 60 + 46 + parsed.timeZoneOffset.inMinutes) % (24 * 60);
      expect(parsed.hour, minutesOfDay ~/ 60);
      expect(parsed.minute, minutesOfDay % 60);
    });

    test('a naive string is already local and passes through unchanged', () {
      final parsed = parseTimestamp('2026-09-07T22:46:43.946')!;
      expect(parsed.isUtc, isFalse);
      expect(parsed, DateTime(2026, 9, 7, 22, 46, 43, 946));
      expect(parsed.hour, 22);
      expect(parsed.minute, 46);
    });

    test('keeps tryParse semantics for null, non-strings and garbage', () {
      expect(parseTimestamp(null), isNull);
      expect(parseTimestamp(1757267203946), isNull);
      expect(parseTimestamp('not a date'), isNull);
    });

    test('instant comparisons are unaffected by localisation', () {
      const later = '2026-09-07T19:00:00.000Z';
      final a = parseTimestamp(wire)!;
      final b = parseTimestamp(later)!;
      expect(b.isAfter(a), isTrue);
      expect(a.isAfter(b), isFalse);
      expect(
        b.isAfter(a),
        DateTime.parse(later).isAfter(DateTime.parse(wire)),
      );
      expect(
        a.compareTo(b),
        DateTime.parse(wire).compareTo(DateTime.parse(later)),
      );
      expect(
        b.difference(a),
        const Duration(hours: 1, minutes: 13, seconds: 16, milliseconds: 54),
      );
    });

    test('an epoch-built UTC string localises exactly like a server row', () {
      // chat_providers builds the optimistic bubble from the outbox's epoch
      // millis with isUtc: true so it carries the same trailing Z as a
      // server row and the two can never disagree on the clock or the day.
      final pending = DateTime.fromMillisecondsSinceEpoch(
        instant.millisecondsSinceEpoch,
        isUtc: true,
      ).toIso8601String();
      expect(pending, endsWith('Z'));
      expect(parseTimestamp(pending), parseTimestamp(wire));
    });
  });
}
