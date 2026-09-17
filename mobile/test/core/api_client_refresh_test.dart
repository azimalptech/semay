// The two backstops behind the refresh storm (docs/08_OPERATIONS.md §3a):
// the refresh margin follows the token's own lifetime, so a short TTL can no
// longer make every token "about to expire" from the moment it is issued;
// and the circuit breaker refuses a sixth refresh inside a minute, so the
// next loop of this kind burns 30 s of "unreachable" instead of the
// /auth/refresh rate limit shared by every phone behind one carrier NAT.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';

import '../support/fake_realtime.dart';

void main() {
  group('AccessTokenSource.minRemainingFor', () {
    test('60 s at the production TTL, a third of a short one', () {
      expect(
        AccessTokenSource.minRemainingFor(fakeJwt('u', ttl: const Duration(minutes: 15))),
        const Duration(seconds: 60),
      );
      expect(
        AccessTokenSource.minRemainingFor(fakeJwt('u', ttl: const Duration(seconds: 180))),
        const Duration(seconds: 60),
      );
      // The TTL of the reproduction: 40 s against a flat 60 s refreshed on
      // every connect.
      expect(
        AccessTokenSource.minRemainingFor(fakeJwt('u', ttl: const Duration(seconds: 40))),
        const Duration(seconds: 40) ~/ 3,
      );
    });

    test('an unreadable token gets the production margin', () {
      expect(AccessTokenSource.minRemainingFor('not-a-jwt'), const Duration(seconds: 60));
    });
  });

  group('RefreshCircuitBreaker', () {
    test('five refreshes in a minute pass, the sixth is refused for 30 s', () {
      var now = DateTime(2026, 9, 16, 12);
      final breaker = RefreshCircuitBreaker(now: () => now);
      for (var i = 0; i < RefreshCircuitBreaker.maxInWindow; i++) {
        expect(breaker.allow(), isTrue, reason: 'refresh #${i + 1}');
        now = now.add(const Duration(seconds: 1));
      }
      expect(breaker.allow(), isFalse);
      expect(breaker.isOpen, isTrue);

      now = now.add(RefreshCircuitBreaker.pause - const Duration(seconds: 1));
      expect(breaker.allow(), isFalse, reason: 'still open a second before the pause ends');

      now = now.add(const Duration(seconds: 2));
      expect(breaker.isOpen, isFalse);
      expect(breaker.allow(), isTrue, reason: 'closed again, with a clean window');
    });

    test('a phone renewing its token normally never trips it', () {
      var now = DateTime(2026, 9, 16, 12);
      final breaker = RefreshCircuitBreaker(now: () => now);
      // One refresh per 20 s is already three times the production cadence.
      for (var i = 0; i < 12; i++) {
        expect(breaker.allow(), isTrue, reason: 'refresh #${i + 1}');
        now = now.add(const Duration(seconds: 20));
      }
      expect(breaker.isOpen, isFalse);
    });
  });
}
