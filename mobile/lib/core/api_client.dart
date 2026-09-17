import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n.dart';
import 'session.dart';

// --dart-define=API_BASE_URL=... overrides this, mirroring the existing
// EMULATOR_HOST override pattern in main.dart. 'localhost' (not 10.0.2.2)
// reaches the dev machine from a physical device over `adb reverse
// tcp:8080 tcp:8080` — one rule covers both REST and WS since server/ serves
// both off the same Fastify port.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8080/api/v1',
);

/// Mirrors the shape of OtpException/OtpLockedException in auth_service.dart
/// so screens keep their existing catch-and-display UX.
class ApiException implements Exception {
  ApiException(this.statusCode, this.error, {this.body});

  final int? statusCode;
  final String error;
  final Map<String, dynamic>? body;

  @override
  String toString() => 'ApiException($statusCode, $error)';
}

/// What to SHOW for a failed save, in the user's language. ApiException's
/// toString() is for logs ("ApiException(400, INVALID_INPUT)") and used to be
/// what the profile-edit SnackBars displayed verbatim; this maps the handful
/// of outcomes a user can act on and folds everything else (401/403, 5xx, an
/// unexpected shape, a non-API error) into a plain "could not save".
String describeApiError(S s, Object e) {
  if (e is! ApiException) return s.saveFailed;
  // No status = the request never got an answer (connection refused, timeout,
  // dropped socket — _mapError's REQUEST_FAILED).
  // statusCode == null is the ONLY "no answer" case — _mapError below leaves
  // it null precisely when there was no HTTP response. `error` is not a
  // second test for it: _mapError also falls back to REQUEST_FAILED for a
  // real response whose body isn't the API's `{error}` shape (an nginx
  // 502/504 page, an empty 500, a 413), and reporting those as "no internet"
  // sent people to check their SIM while the server was the thing failing.
  if (e.statusCode == null) return s.noConnection;
  if (e.statusCode == 400 && e.error == 'INVALID_INPUT') return s.invalidInput;
  if (e.statusCode == 429) return s.tooManyRequests;
  if (e.statusCode! >= 500) return s.serverError;
  return s.saveFailed;
}

ApiException _mapError(DioException e) {
  final body = e.response?.data;
  final error = body is Map && body['error'] is String
      ? body['error'] as String
      : 'REQUEST_FAILED';
  return ApiException(
    e.response?.statusCode,
    error,
    body: body is Map<String, dynamic> ? body : null,
  );
}

/// Thin REST wrapper — every response is a flat JSON object (`{stores: [...]}`,
/// `{post: {...}}`, etc., see docs/07_MIGRATION.md), so callers destructure
/// the map themselves rather than this class imposing per-endpoint types.
class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', path, query: query);

  Future<Map<String, dynamic>> post(String path, {Object? body}) =>
      _send('POST', path, body: body);

  Future<Map<String, dynamic>> patch(String path, {Object? body}) =>
      _send('PATCH', path, body: body);

  Future<Map<String, dynamic>> delete(String path, {Object? body}) =>
      _send('DELETE', path, body: body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
  }) async {
    try {
      final res = await _dio.request<dynamic>(
        path,
        queryParameters: query,
        data: body,
        options: Options(method: method),
      );
      final data = res.data;
      if (data == null) return const {};
      if (data is Map<String, dynamic>) return data;
      throw ApiException(res.statusCode, 'UNEXPECTED_RESPONSE_SHAPE');
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }
}

/// Why a refresh did not produce a new token. The two failures are handled
/// very differently: a refresh token the server explicitly REJECTED (401
/// SESSION_INVALID) means the session is over (log out); anything else — a
/// server we could not reach, a 429, a 5xx — means nothing about the session.
/// Logging out over those threw people back to the phone screen every time the
/// network hiccuped mid-401, and later every ~15 minutes once a single lost
/// refresh response had left the phone with a rotated-away token.
enum RefreshOutcome { ok, rejected, unreachable }

Future<RefreshOutcome>? _refreshInFlight;

/// Stops a refresh storm. Five refreshes inside a minute is not a phone
/// renewing a 15-minute token — it is a loop: the realtime client's connect
/// refreshed, the refresh was mistaken for a login, the connect restarted and
/// refreshed again (docs/08_OPERATIONS.md §3a), ~600 times in 6 s until the
/// server's rate limiter ended it. Each turn rotated the refresh token and
/// burned the `/auth/refresh` budget shared by every phone behind the same
/// carrier NAT. That loop is fixed at its root; this is the backstop for the
/// next one. While open, refreshes report `unreachable`, which every caller
/// already treats as "try again later" without touching the session.
class RefreshCircuitBreaker {
  RefreshCircuitBreaker({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const window = Duration(seconds: 60);
  static const maxInWindow = 5;
  static const pause = Duration(seconds: 30);

  final DateTime Function() _now;
  final _attempts = <DateTime>[];
  DateTime? _openUntil;

  /// True while refreshes are being refused.
  bool get isOpen {
    final until = _openUntil;
    if (until == null) return false;
    if (_now().isBefore(until)) return true;
    _openUntil = null;
    _attempts.clear();
    return false;
  }

  /// Records one refresh attempt; false when it must be refused instead.
  bool allow() {
    if (isOpen) return false;
    final now = _now();
    _attempts.removeWhere((t) => now.difference(t) > window);
    if (_attempts.length >= maxInWindow) {
      _openUntil = now.add(pause);
      debugPrint(
        'api: ${_attempts.length} token refreshes in ${window.inSeconds} s — '
        'refusing refreshes for ${pause.inSeconds} s',
      );
      return false;
    }
    _attempts.add(now);
    return true;
  }
}

final _refreshBreaker = RefreshCircuitBreaker();

/// Single-flight: the REST interceptor and the realtime client can both
/// discover an expired token in the same instant, and the server rotates the
/// refresh token on every call — two concurrent refreshes would have the
/// second one presenting an already-revoked token and getting the session
/// killed for no reason.
Future<RefreshOutcome> _tryRefresh(Ref ref) {
  final inFlight = _refreshInFlight;
  if (inFlight != null) return inFlight;
  if (!_refreshBreaker.allow()) return Future.value(RefreshOutcome.unreachable);
  return _refreshInFlight = _doRefresh(ref).whenComplete(() => _refreshInFlight = null);
}

/// Refresh: one attempt, and one quick retry if the server could not be
/// reached or answered 429/5xx. The retry is what heals the common case of a
/// single lost packet, and it is safe because the server keeps accepting a
/// just-rotated token for a grace window — a first attempt whose RESPONSE was
/// lost (the server did rotate) is healed by presenting the same token again,
/// not turned into a logout. A second miss is left to the next request, which
/// refreshes again; stacking more waits here would only stall whatever
/// triggered the refresh.
Future<RefreshOutcome> _doRefresh(Ref ref) async {
  final store = ref.read(secureSessionStoreProvider);
  final refreshToken = await store.readRefreshToken();
  if (refreshToken == null) return RefreshOutcome.rejected;

  var outcome = await _postRefresh(ref, store, refreshToken);
  if (outcome == RefreshOutcome.unreachable) {
    await Future<void>.delayed(_refreshRetryDelay);
    outcome = await _postRefresh(ref, store, refreshToken);
  }
  return outcome;
}

const _refreshRetryDelay = Duration(seconds: 2);

/// Deliberately uses a bare Dio (no interceptor) — routing it through the same
/// interceptor that triggers refreshes would recurse.
Future<RefreshOutcome> _postRefresh(
  Ref ref,
  SecureSessionStore store,
  String refreshToken,
) async {
  try {
    final res = await Dio(
      BaseOptions(
        baseUrl: apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    ).post<Map<String, dynamic>>('/auth/refresh', data: {'refreshToken': refreshToken});
    final data = res.data!;
    // A logout that completed while this request was in flight wins:
    // persisting these tokens would resurrect the session the user just
    // ended (and leave the rotated server session unrevoked).
    if (await store.readRefreshToken() != refreshToken) return RefreshOutcome.rejected;
    // rotateSession (server-side) issues a NEW refresh token on every call —
    // must persist it, or every later refresh presents a retired token and,
    // once the server's reuse grace has passed, fails for good.
    await ref.read(sessionControllerProvider.notifier).setTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
    return RefreshOutcome.ok;
  } on DioException catch (e) {
    // The ONLY verdict on the session is the server saying so: 401
    // SESSION_INVALID — this refresh token was revoked (signed out on this
    // device, account deleted) or replayed long after it was rotated away.
    // Everything else says nothing about the session: 429 from the rate
    // limiter (carrier NAT puts many phones behind one IP), any 5xx, a
    // timeout, a dropped socket, even a 400. The old rule counted every
    // 400/401/403 as final, and logging out over a non-verdict is precisely
    // the "signed out every 15 minutes" bug.
    final body = e.response?.data;
    final error = body is Map ? body['error'] : null;
    if (e.response?.statusCode == 401 && error == 'SESSION_INVALID') {
      return RefreshOutcome.rejected;
    }
    return RefreshOutcome.unreachable;
  } catch (_) {
    return RefreshOutcome.unreachable;
  }
}

/// Hands out an access token that will still be valid when it reaches the
/// server, refreshing first if it is expired or about to be. Used by the
/// realtime client before every socket connect (see session.dart's
/// jwtExpiresAt for why a socket can't rely on the interceptor's after-the-
/// fact retry). Null means there is no session to connect as.
class AccessTokenSource {
  AccessTokenSource(this._ref);

  final Ref _ref;

  /// Refresh when this little (or less) is left — enough for the connect
  /// handshake to complete before the server's own expiry check would fail.
  /// 60 s at the production TTL (15 min), a third of the lifetime for a TTL
  /// under 3 min (test and ops configs): against a flat 60 s a 40 s token was
  /// "about to expire" the moment it was issued, so every connect refreshed —
  /// and, with the session-change bug that used to restart the connect on
  /// every refresh, looped (docs/08_OPERATIONS.md §3a).
  static const _maxMinRemaining = Duration(seconds: 60);

  @visibleForTesting
  static Duration minRemainingFor(String accessToken) {
    final lifetime = jwtLifetime(accessToken);
    if (lifetime == null) return _maxMinRemaining;
    final third = lifetime ~/ 3;
    return third < _maxMinRemaining ? third : _maxMinRemaining;
  }

  Future<String?> validToken({bool forceRefresh = false}) async {
    final store = _ref.read(secureSessionStoreProvider);
    final current = await store.readAccessToken();
    if (current == null) return null;
    final exp = jwtExpiresAt(current);
    final expired = exp == null || exp.difference(DateTime.now().toUtc()) < Duration.zero;
    final fresh =
        !expired && exp.difference(DateTime.now().toUtc()) > minRemainingFor(current);
    if (fresh && !forceRefresh) return current;

    switch (await _tryRefresh(_ref)) {
      case RefreshOutcome.ok:
        return store.readAccessToken();
      case RefreshOutcome.rejected:
        // The refresh token is dead: the session is over, same as the
        // interceptor concludes on its own unrecoverable 401.
        await _ref.read(sessionControllerProvider.notifier).logout();
        return null;
      case RefreshOutcome.unreachable:
        // Can't reach the server right now. If the token hasn't actually
        // expired yet, let the connect attempt go ahead with it — the server
        // may be reachable over the socket path even if the refresh wasn't;
        // an expired one is pointless to try and the caller backs off.
        return expired ? null : current;
    }
  }
}

final accessTokenSourceProvider = Provider<AccessTokenSource>((ref) => AccessTokenSource(ref));

Dio _buildDio(Ref ref) {
  // receive/send timeouts too, not just connect: a request sitting on a
  // half-open connection (Wi-Fi dropped mid-flight, carrier NAT reset) used to
  // hang forever, and since the outbox drains one item at a time, one hung
  // message send silently wedged every message queued behind it until the app
  // was restarted. Media uploads are unaffected — they go through a bare Dio.
  final dio = Dio(
    BaseOptions(
      baseUrl: apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await ref.read(secureSessionStoreProvider).readAccessToken();
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
        handler.next(options);
      },
      onError: (error, handler) async {
        final status = error.response?.statusCode;
        final alreadyRetried = error.requestOptions.extra['retried'] == true;
        // Covers both plain expiry (401 UNAUTHENTICATED) and a stale-but-
        // not-yet-expired token whose claims_version fell behind (401
        // CLAIMS_STALE, e.g. just-granted store-admin rights) — both self-
        // heal the same way: refresh once, retry once.
        if (status == 401 && !alreadyRetried) {
          switch (await _tryRefresh(ref)) {
            case RefreshOutcome.ok:
              final req = error.requestOptions..extra['retried'] = true;
              final token = await ref.read(secureSessionStoreProvider).readAccessToken();
              req.headers['Authorization'] = 'Bearer $token';
              try {
                final res = await ref.read(_dioProvider).fetch<dynamic>(req);
                return handler.resolve(res);
              } on DioException catch (retryError) {
                return handler.next(retryError);
              }
            case RefreshOutcome.rejected:
              await ref.read(sessionControllerProvider.notifier).logout();
            case RefreshOutcome.unreachable:
              // Leave the session alone — the caller sees the 401 as a
              // failed request (the outbox treats it as retryable) and the
              // next attempt refreshes again once the server is reachable.
              break;
          }
        }
        handler.next(error);
      },
    ),
  );

  return dio;
}

final _dioProvider = Provider<Dio>((ref) => _buildDio(ref));

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(ref.watch(_dioProvider));
});
