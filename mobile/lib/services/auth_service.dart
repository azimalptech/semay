import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/session.dart';

/// Thrown by [AuthService.sendOtp]/[AuthService.verifyOtp] for anything the
/// OTP screen needs to react to specifically (wrong code, lockout) rather
/// than just display as a generic error string.
///
/// [message] is ALWAYS a server error CODE (SCREAMING_SNAKE), never prose:
/// three of these used to be English sentences built here ("Invalid code",
/// "Please wait 45s before requesting another code", "That phone number is
/// already in use") and the screens render the message verbatim — so English
/// landed on a Turkmen/Russian-only app, directly above Turkmen copy. Screens
/// go through [describeOtpError] instead.
class OtpException implements Exception {
  OtpException(
    this.message, {
    this.attemptsRemaining,
    this.retryAfterSeconds,
    this.statusCode,
  });

  /// The server's error code, e.g. OTP_INVALID / OTP_COOLDOWN / REQUEST_FAILED.
  final String message;
  final int? attemptsRemaining;

  /// OTP_COOLDOWN only: seconds left on the server's resend cooldown.
  final int? retryAfterSeconds;

  /// Carried so [describeOtpError] can tell a 429 or a 5xx apart from an
  /// application error. It matters because a rate-limited or 5xx response does
  /// NOT come back in the API's `{error: "CODE"}` shape — fastify-rate-limit
  /// answers `{error: "Too Many Requests", ...}`, so `message` would be
  /// English prose, which is the exact thing this class must never display.
  final int? statusCode;

  @override
  String toString() => message;
}

/// What to SHOW for a failed OTP/phone step, in the user's language. Every
/// screen that displays an auth failure (login OTP, phone entry, the profile's
/// change-phone flow, the signup name screen) must use this: [OtpException]
/// carries a bare code and [ApiException]'s toString is for logs.
String describeOtpError(S s, Object e) {
  if (e is! OtpException) return describeApiError(s, e);
  switch (e.message) {
    case 'OTP_INVALID':
      return s.incorrectCode;
    case 'OTP_COOLDOWN':
      final retryAfter = e.retryAfterSeconds;
      return retryAfter != null
          ? s.waitBeforeNewCode(retryAfter)
          : s.waitBeforeNewCodeGeneric;
    case 'PHONE_ALREADY_IN_USE':
      return s.phoneAlreadyInUse;
    case 'REQUEST_FAILED':
      // No answer at all from the API — the one code worth naming as such.
      return s.noConnection;
    case 'INVALID_INPUT':
      return s.invalidInput;
    default:
      // Same ladder describeApiError uses, for the same reasons.
      final status = e.statusCode;
      if (status == 429) return s.tooManyRequests;
      if (status != null && status >= 500) return s.serverError;
      return s.saveFailed;
  }
}

/// The phone is locked out (5 wrong attempts) until [lockedUntil].
class OtpLockedException implements Exception {
  OtpLockedException(this.lockedUntil);

  final DateTime lockedUntil;
}

/// A store admin/superadmin tried to self-delete. Their stores and accepted
/// orders would cascade other users' data, so that path needs the superadmin
/// panel rather than the in-app button.
class AccountDeletionBlockedException implements Exception {}

/// The OTP was correct but this phone has no account yet and no name was
/// supplied. The code remains valid — collect a name and call verifyOtp again
/// with the SAME code. See server/src/auth/otpStore.ts NameRequiredError.
class NameRequiredException implements Exception {}

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
  /// phone is locked out, and [NameRequiredException] when this phone has no
  /// account yet and no [name] was supplied — the server creates the account
  /// and its name in one transaction, so a nameless row can't exist.
  ///
  /// The code is NOT consumed by a NAME_REQUIRED rejection: the caller collects
  /// a name and calls this again with the same [code].
  Future<void> verifyOtp(String phone, String code, {String? name}) async {
    final Map<String, dynamic> data;
    try {
      data = await _api.post(
        '/auth/otp/verify',
        body: {'phone': phone, 'code': code, 'name': ?name},
      );
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
        throw OtpException('PHONE_ALREADY_IN_USE', statusCode: e.statusCode);
      }
      throw _mapOtpException(e);
    }
    _ref.invalidate(userProfileProvider);
  }

  /// Permanently deletes this account, then clears the local session.
  ///
  /// The server anonymizes the row in place (orders belong to the store, not the
  /// customer — see server/src/users/service.ts) and immediately revokes the
  /// access token, so no local call after this can succeed. Local logout is
  /// therefore unconditional once the server confirms: leaving a dead token in
  /// secure storage would just strand the app on a screen every request 401s on.
  Future<void> deleteAccount() async {
    try {
      await _api.delete('/users/me');
    } on ApiException catch (e) {
      if (e.error == 'STORE_OWNER_CANNOT_DELETE') {
        throw AccountDeletionBlockedException();
      }
      // ALREADY_DELETED (410) means the account is gone and only this device
      // hadn't noticed — fall through to the local logout below.
      if (e.error != 'ALREADY_DELETED') rethrow;
    }
    await _ref.read(sessionControllerProvider.notifier).logout();
  }

  Future<void> signOut() async {
    // Best-effort revoke. Sessions last until logout, so without this the
    // server-side rows would stay live for up to two idle years; the server
    // ends the whole login family, dangling siblings from lost refresh
    // responses included.
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
        // The CODE, with the number alongside it — the screens localise both
        // through describeOtpError. This used to build an English sentence.
        return OtpException(
          'OTP_COOLDOWN',
          retryAfterSeconds: body?['retryAfterSeconds'] as int?,
        );
      case 'OTP_INVALID':
        return OtpException(
          'OTP_INVALID',
          attemptsRemaining: body?['attemptsRemaining'] as int?,
        );
      case 'NAME_REQUIRED':
        // Not an error to show — the code was right, we just need a name
        // before the account can be created. The OTP is still valid.
        return NameRequiredException();
      default:
        // e.error is only a CODE when the body was the API's {error} shape;
        // a 429 from fastify-rate-limit or an nginx 502 page is not, so the
        // status is carried along and describeOtpError decides from it.
        return OtpException(e.error, statusCode: e.statusCode);
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
