import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/session.dart';

/// Thrown by [AuthService.sendOtp]/[AuthService.verifyOtp] for anything the
/// OTP screen needs to react to specifically (wrong code, lockout) rather
/// than just display as a generic error string.
class OtpException implements Exception {
  OtpException(this.message, {this.attemptsRemaining});

  final String message;
  final int? attemptsRemaining;

  @override
  String toString() => message;
}

/// The phone is locked out (5 wrong attempts) until [lockedUntil].
class OtpLockedException implements Exception {
  OtpLockedException(this.lockedUntil);

  final DateTime lockedUntil;
}

enum AppRole { unauthenticated, user, admin, superadmin }

/// Kept as the same name/shape every screen and router.dart already expects
/// (an `AsyncValue`-producing provider) — the actual implementation moved to
/// session.dart's `SessionController`, which decodes role/storeIds/
/// claimsVersion straight out of the access JWT rather than watching a live
/// Firestore doc. This is a plain alias (same provider identity), not a
/// wrapper, so it costs nothing extra.
final authStateChangesProvider = sessionControllerProvider;

/// The signed-in user's own profile — fetched once per session rather than
/// live-streamed (no realtime channel exists or is needed for "my own
/// profile fields"; see docs/07_MIGRATION.md Phase 9). Re-fetched via
/// `ref.invalidate` after any self-mutation (completeProfile, language/
/// darkMode changes, etc.) so the router and settings screen see the new
/// value immediately.
final userProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return null;
  final data = await ref.watch(apiClientProvider).get('/users/me');
  return data['user'] as Map<String, dynamic>?;
});

final appRoleProvider = FutureProvider<AppRole>((ref) async {
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return AppRole.unauthenticated;
  switch (session.role) {
    case 'admin':
      return AppRole.admin;
    case 'superadmin':
      return AppRole.superadmin;
    default:
      return AppRole.user;
  }
});

/// Store ids an admin manages, straight from the access token's embedded
/// claims. Empty for non-admins.
final storeIdsProvider = FutureProvider<List<String>>((ref) async {
  final session = await ref.watch(authStateChangesProvider.future);
  return session?.storeIds ?? const [];
});

class AuthService {
  AuthService(this._api, this._ref);

  final ApiClient _api;
  final Ref _ref;

  /// Requests a code via the real /auth/otp/send endpoint. Returns the
  /// plaintext code when the server is running with OTP_DEV_MODE=true (no
  /// real SMS gateway wired up in dev — see server/.env.example), so the OTP
  /// screen can show it in a dev-only banner; null otherwise.
  Future<String?> sendOtp(String phone) async {
    if (!_isValidPhone(phone)) throw Exception('Invalid phone number');
    try {
      final data = await _api.post('/auth/otp/send', body: {'phone': phone});
      return data['devCode'] as String?;
    } on ApiException catch (e) {
      throw _mapOtpException(e);
    }
  }

  /// Verifies the code, then persists the resulting access/refresh tokens.
  /// Throws [OtpException] for a wrong code or [OtpLockedException] once the
  /// phone is locked out.
  Future<void> verifyOtp(String phone, String code) async {
    final Map<String, dynamic> data;
    try {
      data = await _api.post('/auth/otp/verify', body: {'phone': phone, 'code': code});
    } on ApiException catch (e) {
      throw _mapOtpException(e);
    }

    await _ref.read(sessionControllerProvider.notifier).setTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
    _ref.invalidate(userProfileProvider);
  }

  Future<void> completeProfile(String name) async {
    await _api.patch('/users/me', body: {'name': name});
    _ref.invalidate(userProfileProvider);
  }

  /// Re-verifies ownership of a *new* phone number (same sendOtp code + this)
  /// before repointing this account's phone at it — phone is the OTP login
  /// identity, so it can't be changed by a plain profile field update.
  Future<void> changePhone(String phone, String code) async {
    try {
      await _api.post('/auth/change-phone', body: {'phone': phone, 'code': code});
    } on ApiException catch (e) {
      if (e.error == 'PHONE_ALREADY_IN_USE') {
        throw OtpException('That phone number is already in use');
      }
      throw _mapOtpException(e);
    }
    _ref.invalidate(userProfileProvider);
  }

  Future<void> signOut() async {
    // Best-effort revoke — the server-side session row would otherwise just
    // age out after 30 days, but there's no reason to wait for that.
    try {
      final refreshToken = await _ref.read(secureSessionStoreProvider).readRefreshToken();
      if (refreshToken != null) {
        await _api.post('/auth/logout', body: {'refreshToken': refreshToken});
      }
    } catch (_) {
      // Logging out client-side must succeed regardless of network state.
    }
    await _ref.read(sessionControllerProvider.notifier).logout();
  }

  Exception _mapOtpException(ApiException e) {
    final body = e.body;
    switch (e.error) {
      case 'OTP_LOCKED':
        final lockedUntilStr = body?['lockedUntil'] as String?;
        final lockedUntil = lockedUntilStr != null ? DateTime.tryParse(lockedUntilStr) : null;
        return OtpLockedException(lockedUntil ?? DateTime.now().add(const Duration(hours: 1)));
      case 'OTP_COOLDOWN':
        final retryAfter = body?['retryAfterSeconds'] as int?;
        return OtpException(
          retryAfter != null
              ? 'Please wait ${retryAfter}s before requesting another code'
              : 'Please wait before requesting another code',
        );
      case 'OTP_INVALID':
        return OtpException(
          'Invalid code',
          attemptsRemaining: body?['attemptsRemaining'] as int?,
        );
      default:
        return OtpException(e.error);
    }
  }

  // +993 followed by exactly 8 digits, no more, no less — matches the
  // formatters on both phone-entry TextFields (phone_entry_screen.dart,
  // edit_profile_screen.dart), which already constrain input to digits-only
  // and cap length before it ever reaches here.
  bool _isValidPhone(String phone) {
    return RegExp(r'^\+993\d{8}$').hasMatch(phone);
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(ref.watch(apiClientProvider), ref);
});
