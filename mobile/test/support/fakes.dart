import 'dart:async';

import 'package:dio/dio.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/session.dart';

/// Records every call; behaviour is scripted per test through [onGet],
/// [onPatch], [onPost] and [onDelete] — the verbs the profile-edit screens,
/// the story providers and the story viewer (delete, mark-seen, view) use.
/// Anything unscripted answers `{}`.
class FakeApi extends ApiClient {
  FakeApi() : super(Dio());

  final calls = <String>[];
  FutureOr<Map<String, dynamic>> Function(String path)? onGet;
  FutureOr<Map<String, dynamic>> Function(String path, Object? body)? onPatch;
  FutureOr<Map<String, dynamic>> Function(String path, Object? body)? onPost;
  FutureOr<Map<String, dynamic>> Function(String path, Object? body)? onDelete;

  int count(String call) => calls.where((c) => c == call).length;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add('GET $path');
    return await onGet?.call(path) ?? const {};
  }

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    calls.add('PATCH $path');
    return await onPatch?.call(path, body) ?? const {};
  }

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    calls.add('POST $path');
    return await onPost?.call(path, body) ?? const {};
  }

  @override
  Future<Map<String, dynamic>> delete(String path, {Object? body}) async {
    calls.add('DELETE $path');
    return await onDelete?.call(path, body) ?? const {};
  }
}

/// A signed-in session without touching secure storage.
class FakeSession extends SessionController {
  FakeSession({this.role = 'user', this.storeIds = const []});

  final String role;
  final List<String> storeIds;

  @override
  Future<SessionClaims?> build() async => SessionClaims(
    uid: 'u1',
    role: role,
    storeIds: storeIds,
    claimsVersion: 1,
  );
}
