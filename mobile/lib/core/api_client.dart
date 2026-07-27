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

/// Refresh call deliberately uses a bare Dio (no interceptor) — routing it
/// through the same interceptor that triggers refreshes would recurse.
Future<bool> _tryRefresh(Ref ref) async {
  final store = ref.read(secureSessionStoreProvider);
  final refreshToken = await store.readRefreshToken();
  if (refreshToken == null) return false;

  try {
    final res = await Dio(BaseOptions(baseUrl: apiBaseUrl)).post<Map<String, dynamic>>(
      '/auth/refresh',
      data: {'refreshToken': refreshToken},
    );
    final data = res.data!;
    // rotateSession (server-side) issues a NEW refresh token on every call —
    // must persist it, or the next refresh attempt reuses an already-revoked
    // one and fails permanently instead of just once.
    await ref.read(sessionControllerProvider.notifier).setTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
    return true;
  } catch (_) {
    return false;
  }
}

Dio _buildDio(Ref ref) {
  final dio = Dio(BaseOptions(baseUrl: apiBaseUrl, connectTimeout: const Duration(seconds: 15)));

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
          final refreshed = await _tryRefresh(ref);
          if (refreshed) {
            final req = error.requestOptions..extra['retried'] = true;
            final token = await ref.read(secureSessionStoreProvider).readAccessToken();
            req.headers['Authorization'] = 'Bearer $token';
            try {
              final res = await ref.read(_dioProvider).fetch<dynamic>(req);
              return handler.resolve(res);
            } on DioException catch (retryError) {
              return handler.next(retryError);
            }
          } else {
            await ref.read(sessionControllerProvider.notifier).logout();
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
