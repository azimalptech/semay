// The wiring, not the helper: test/core/outbox_refresh_test.dart proves
// refetchWhenOutboxSends works against a probe provider, which stays green
// even if profile_providers.dart stops calling it — i.e. even if the reported
// bug ("liked/saved only update after force-quitting") comes straight back.
// This drives the REAL likedPostIdsProvider/savedPostIdsProvider.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/core/session.dart';
import 'package:semay/features/profile/profile_providers.dart';

/// Long enough for the real 400 ms debounce plus the re-run it schedules.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 700));

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add(path);
    return {
      'posts': [
        {'id': 'post-${calls.where((c) => c == path).length}'},
      ],
    };
  }
}

class _FakeSession extends SessionController {
  @override
  Future<SessionClaims?> build() async => const SessionClaims(
    uid: 'u1',
    role: 'user',
    storeIds: [],
    claimsVersion: 1,
  );
}

void main() {
  late StreamController<OutboxKind> completed;
  late _FakeApi api;
  late ProviderContainer container;

  setUp(() {
    completed = StreamController<OutboxKind>.broadcast();
    api = _FakeApi();
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionControllerProvider.overrideWith(_FakeSession.new),
        outboxCompletedProvider.overrideWithValue(completed.stream),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    completed.close();
  });

  int callsTo(String path) => api.calls.where((c) => c == path).length;

  test('the liked grid re-reads /users/me/liked once the like lands', () async {
    final sub = container.listen(likedPostIdsProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await container.read(likedPostIdsProvider.future), ['post-1']);
    expect(callsTo('/users/me/liked'), 1);

    // A save draining is not this list's business.
    completed.add(OutboxKind.save);
    await _settle();
    expect(callsTo('/users/me/liked'), 1);

    // The like reached the server — only now is a refetch not a re-cache of
    // the pre-toggle answer.
    completed.add(OutboxKind.like);
    await _settle();
    expect(callsTo('/users/me/liked'), 2);
    expect(await container.read(likedPostIdsProvider.future), ['post-2']);

    // Unlike too: the post has to leave the grid on its own.
    completed.add(OutboxKind.unlike);
    await _settle();
    expect(callsTo('/users/me/liked'), 3);
  });

  test('the saved grid re-reads /users/me/saved on save and unsave', () async {
    final sub = container.listen(savedPostIdsProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(savedPostIdsProvider.future);
    expect(callsTo('/users/me/saved'), 1);

    completed.add(OutboxKind.like);
    await _settle();
    expect(callsTo('/users/me/saved'), 1);

    completed.add(OutboxKind.save);
    await _settle();
    expect(callsTo('/users/me/saved'), 2);

    completed.add(OutboxKind.unsave);
    await _settle();
    expect(callsTo('/users/me/saved'), 3);
  });

  test('nothing is re-read once the grid is gone', () async {
    final sub = container.listen(likedPostIdsProvider, (_, _) {});
    await container.read(likedPostIdsProvider.future);
    expect(callsTo('/users/me/liked'), 1);

    sub.close(); // the screen was popped; the provider is autoDispose
    await _settle();

    completed.add(OutboxKind.like);
    await _settle();
    expect(callsTo('/users/me/liked'), 1);
  });
}
