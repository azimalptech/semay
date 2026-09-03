import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Locally-decoded claims from the access JWT `server/` issues — role,
/// storeIds, and claimsVersion are embedded in the token at issuance (see
/// server/src/auth/claims.ts), so reading them needs no network round trip.
/// This is what replaces the old `_syncedIdTokenResultProvider` hack: that
/// existed to force-refresh a cached Firebase ID token when a live Firestore
/// doc disagreed with it; the new design refreshes proactively instead (see
/// api_client.dart), so nothing here needs to compare against a live doc.
class SessionClaims {
  const SessionClaims({
    required this.uid,
    required this.role,
    required this.storeIds,
    required this.claimsVersion,
  });

  final String uid;
  final String role; // "user" | "admin" | "superadmin"
  final List<String> storeIds;
  final int claimsVersion;

  static SessionClaims? tryDecode(String accessToken) {
    try {
      final parts = accessToken.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(_decodeBase64Segment(parts[1])) as Map<String, dynamic>;
      return SessionClaims(
        uid: payload['sub'] as String,
        role: payload['role'] as String? ?? 'user',
        storeIds: (payload['storeIds'] as List<dynamic>?)?.cast<String>() ?? const [],
        claimsVersion: payload['claimsVersion'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Expiry (`exp` claim) of an access JWT, or null when it can't be read. The
/// realtime client checks this BEFORE opening a socket: unlike a REST call,
/// which the interceptor in api_client.dart can retry with a refreshed header,
/// a WebSocket handed an expired token is simply closed by the server (4401)
/// and there is nothing to retry — the token has to be fresh going in.
DateTime? jwtExpiresAt(String accessToken) {
  try {
    final parts = accessToken.split('.');
    if (parts.length != 3) return null;
    final payload =
        jsonDecode(_decodeBase64Segment(parts[1])) as Map<String, dynamic>;
    final exp = payload['exp'];
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}

String _decodeBase64Segment(String segment) {
  var normalized = segment.replaceAll('-', '+').replaceAll('_', '/');
  switch (normalized.length % 4) {
    case 2:
      normalized += '==';
    case 3:
      normalized += '=';
  }
  return utf8.decode(base64.decode(normalized));
}

/// Access + refresh token persistence — flutter_secure_storage backs onto
/// Android Keystore / iOS Keychain, the same trust boundary the old
/// firebase_auth SDK's own token cache had.
class SecureSessionStore {
  SecureSessionStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';

  Future<String?> readAccessToken() => _storage.read(key: _accessKey);
  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  Future<void> save({required String accessToken, required String refreshToken}) async {
    await _storage.write(key: _accessKey, value: accessToken);
    await _storage.write(key: _refreshKey, value: refreshToken);
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }
}

final secureSessionStoreProvider = Provider<SecureSessionStore>((ref) {
  return SecureSessionStore(const FlutterSecureStorage());
});

/// Single source of truth for "am I logged in, and as whom" — null when
/// logged out. `api_client.dart`'s auth interceptor calls [setTokens] after
/// every login/refresh and [logout] on an unrecoverable 401, so this state
/// (and everything derived from it — see auth_service.dart's compat
/// providers) stays correct without any screen needing to know about tokens
/// directly.
class SessionController extends AsyncNotifier<SessionClaims?> {
  @override
  Future<SessionClaims?> build() async {
    final accessToken = await ref.watch(secureSessionStoreProvider).readAccessToken();
    if (accessToken == null) return null;
    return SessionClaims.tryDecode(accessToken);
  }

  Future<void> setTokens({required String accessToken, required String refreshToken}) async {
    await ref.read(secureSessionStoreProvider).save(accessToken: accessToken, refreshToken: refreshToken);
    state = AsyncData(SessionClaims.tryDecode(accessToken));
  }

  Future<void> logout() async {
    await ref.read(secureSessionStoreProvider).clear();
    state = const AsyncData(null);
  }
}

final sessionControllerProvider = AsyncNotifierProvider<SessionController, SessionClaims?>(
  SessionController.new,
);
