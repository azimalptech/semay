import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// very differently: a refresh token the server REJECTED means the session is
/// over (log out); a server we could not REACH means nothing about the
/// session, and logging out over it (which the interceptor used to do) threw
/// people back to the phone screen every time the network hiccuped mid-401.
enum RefreshOutcome { ok, rejected, unreachable }

Future<RefreshOutcome>? _refreshInFlight;

/// Single-flight: the REST interceptor and the realtime client can both
/// discover an expired token in the same instant, and the server rotates the
/// refresh token on every call — two concurrent refreshes would have the
/// second one presenting an already-revoked token and getting the session
/// killed for no reason.
Future<RefreshOutcome> _tryRefresh(Ref ref) {
  return _refreshInFlight ??= _doRefresh(ref).whenComplete(() => _refreshInFlight = null);
}

/// Refresh call deliberately uses a bare Dio (no interceptor) — routing it
/// through the same interceptor that triggers refreshes would recurse.
Future<RefreshOutcome> _doRefresh(Ref ref) async {
  final store = ref.read(secureSessionStoreProvider);
  final refreshToken = await store.readRefreshToken();
  if (refreshToken == null) return RefreshOutcome.rejected;

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
    // must persist it, or the next refresh attempt reuses an already-revoked
    // one and fails permanently instead of just once.
    await ref.read(sessionControllerProvider.notifier).setTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
    return RefreshOutcome.ok;
  } on DioException catch (e) {
    // Only a verdict on the TOKEN itself is a rejection: 401 (revoked or
    // rotated away), 403, 400 (malformed). 429 from the auth rate limiter
    // (60/min per IP, and carrier NAT puts many phones behind one IP — see
    // server config.ts) and any 5xx mean the server is busy, not that the
    // session is over; mapping every 4xx to "rejected" would log a whole
    // cell tower's worth of users out the moment their phones reconnected
    // together.
    final status = e.response?.statusCode;
    if (status == 400 || status == 401 || status == 403) return RefreshOutcome.rejected;
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
  static const _minRemaining = Duration(seconds: 60);

  Future<String?> validToken({bool forceRefresh = false}) async {
    final store = _ref.read(secureSessionStoreProvider);
    final current = await store.readAccessToken();
    if (current == null) return null;
    final exp = jwtExpiresAt(current);
    final expired = exp == null || exp.difference(DateTime.now().toUtc()) < Duration.zero;
    final fresh = !expired && exp.difference(DateTime.now().toUtc()) > _minRemaining;
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
