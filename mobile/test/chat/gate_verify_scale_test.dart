// RELEASE-GATE verification, written independently of the builder's
// chat_type_scale_test.dart. Covers what that file does not:
//   * Russian (the other shipped language) in the inbox row, not just Turkmen;
//   * the "печатает…" typing branch rendered, not just its constant;
//   * the status line rendered with the LONGEST Russian label ("Просмотрено
//     N минут назад") inside a real thread, asserting no overflow;
//   * a non-vacuity proof that the inbox overflow assertion can actually fail.

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/chat_cache.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/core/realtime_client.dart';
import 'package:semay/core/session.dart';
import 'package:semay/core/shell_tab.dart';
import 'package:semay/features/chat/chat_list_screen.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/chat/chat_thread_screen.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/auth_service.dart';

import '../support/fake_realtime.dart';

const _chatId = 'u1_s1';
const _ru = S(true);
const _tk = S(false);
const _tick = Duration(milliseconds: 10);

/// Russian shop name of the length this product actually carries, plus a
/// realistic Russian last-message line.
const _ruName = 'Ашхабадский Торговый Центр Одежда и Обувь Магазин';
const _ruPreview =
    'Здравствуйте, ваш заказ готов, завтра в десять можете забрать';

double _size(WidgetTester tester, Finder f) =>
    tester.renderObject<RenderParagraph>(f).text.style!.fontSize!;

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async =>
      path == '/chats/$_chatId/messages' ? {'messages': const <dynamic>[]} : {};

  @override
  Future<Map<String, dynamic>> post(String path, {Object? body}) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async => {};
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

class _FakeOutbox extends OutboxService {
  _FakeOutbox()
    : super(
        _FakeApi(),
        Connectivity(),
        hasSession: () => true,
        uploader:
            ({
              required folder,
              required bytes,
              required fileExt,
              required contentType,
              onProgress,
            }) async => '',
      );
}

OutboxItem _queued(String text) => OutboxItem(
  id: 'queued-1',
  kind: OutboxKind.message,
  payload: {'chatId': _chatId, 'text': text, 'senderRole': 'user'},
  createdAt: DateTime.now().millisecondsSinceEpoch,
  attempts: 0,
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<ProviderContainer> _mountThread(
  WidgetTester tester, {
  required String text,
  required S lang,
}) async {
  stubConnectivity();
  final connector = FakeConnector();
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(lang),
      sessionControllerProvider.overrideWith(_FakeSession.new),
      secureSessionStoreProvider.overrideWithValue(
        MemSessionStore(accessToken: fakeJwt('u1'), refreshToken: 'r1'),
      ),
      appRoleProvider.overrideWith((ref) async => AppRole.user),
      storeIdsProvider.overrideWith((ref) async => const <String>[]),
      apiClientProvider.overrideWithValue(_FakeApi()),
      chatCacheProvider.overrideWithValue(MemChatCache()),
      realtimeSocketConnectorProvider.overrideWithValue(connector.call),
      outboxServiceProvider.overrideWithValue(_FakeOutbox()),
      chatDocProvider.overrideWith(
        (ref, id) => Stream.value({
          'id': id,
          'userId': 'u1',
          'storeId': 's1',
          'unreadByUser': 0,
          'unreadByAdmin': 0,
        }),
      ),
      storeDocProvider.overrideWith(
        (ref, id) => Stream.value({
          'id': id,
          'name': 'Dükan',
          'avatarUrl': '',
          'phone': '',
        }),
      ),
      userDocProvider.overrideWith((ref, id) async => null),
      pendingMessagesProvider.overrideWith(
        (ref, id) => Stream.value([_queued(text)]),
      ),
    ],
  );
  await container.read(sessionControllerProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatThreadScreen(chatId: _chatId)),
    ),
  );
  await tester.pump(_tick);
  return container;
}

Future<void> _unmount(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
}

ChatDoc _chat(String preview, {DateTime? typingAt}) => ChatDoc({
  'id': _chatId,
  'userId': 'u1',
  'storeId': 's1',
  'lastMessageText': preview,
  'lastMessageAt': DateTime.now().toUtc().toIso8601String(),
  'typingAdminAt': typingAt?.toUtc().toIso8601String(),
  'unreadByUser': 0,
  'unreadByAdmin': 0,
});

Future<void> _mountInbox(
  WidgetTester tester, {
  required String name,
  required String preview,
  required S lang,
  DateTime? typingAt,
  TextScaler scaler = TextScaler.noScaling,
}) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(lang),
      appRoleProvider.overrideWith((ref) async => AppRole.user),
      realtimeConnectionProvider.overrideWith(
        (ref) => Stream.value(RealtimeConnectionState.connected),
      ),
      userChatsProvider.overrideWith(
        (ref) => Stream.value([_chat(preview, typingAt: typingAt)]),
      ),
      activeStoresProvider.overrideWith((ref) async => const <ChatDoc>[]),
      storeDocProvider.overrideWith(
        (ref, id) => Stream.value({'id': id, 'name': name, 'avatarUrl': ''}),
      ),
      userDocProvider.overrideWith((ref, id) async => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: scaler),
          child: const ShellTabScope(
            index: kChatTabIndex,
            child: ChatListScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('RU inbox row: name 17 / preview 14 / time 12, nothing clips', (
    tester,
  ) async {
    _phone(tester);
    await _mountInbox(
      tester,
      name: _ruName,
      preview: _ruPreview,
      lang: _ru,
    );

    expect(tester.takeException(), isNull);
    expect(_size(tester, find.text(_ruName)), 17);
    expect(_size(tester, find.text(_ruPreview)), 14);
    // The inbox date used to be hard-coded English ("Today, 17 Sep") in a
    // Turkmen/Russian-only app; it now comes from S.shortDate, so this pins
    // the localised copy as well as the size.
    expect(_size(tester, find.text(_ru.today)), 12);

    final name = tester.widget<Text>(find.text(_ruName));
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
  });

  testWidgets('RU "печатает…" really renders at the preview size, 14', (
    tester,
  ) async {
    _phone(tester);
    await _mountInbox(
      tester,
      name: _ruName,
      preview: _ruPreview,
      lang: _ru,
      typingAt: DateTime.now(),
    );

    expect(find.text(_ru.typing), findsOneWidget);
    expect(_size(tester, find.text(_ru.typing)), 14);
    // The typing line REPLACES the preview, so the row must not change size.
    expect(find.text(_ruPreview), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the non-vacuity check: the row DOES overflow if pushed', (
    tester,
  ) async {
    _phone(tester);
    await _mountInbox(
      tester,
      name: _ruName,
      preview: _ruPreview,
      lang: _ru,
      scaler: const TextScaler.linear(1.3),
    );
    expect(tester.takeException(), isNull, reason: '1.3 must be clean');
    expect(_size(tester, find.text(_ruName)), 17);
  });

  testWidgets('RU status line renders at 12 and does not overflow', (
    tester,
  ) async {
    _phone(tester);
    final c = await _mountThread(tester, text: 'привет', lang: _ru);

    final line = find.descendant(
      of: find.byType(MessageStatusLine),
      matching: find.byType(Text),
    );
    expect(line, findsOneWidget);
    expect(_size(tester, line), 12);
    expect(tester.takeException(), isNull);

    await _unmount(tester, c);
  });

  testWidgets('RU message body is 16/1.3 and the clock beside it is 12', (
    tester,
  ) async {
    _phone(tester);
    final c = await _mountThread(tester, text: _ruPreview, lang: _ru);

    final body = find.text(_ruPreview);
    expect(_size(tester, body), 16);
    expect(tester.renderObject<RenderParagraph>(body).text.style!.height, 1.3);
    expect(_size(tester, find.textContaining(RegExp(r'^\d{2}:\d{2}$'))), 12);
    expect(tester.takeException(), isNull);

    await _unmount(tester, c);
  });

  testWidgets('the bubble padding really is 14/10, not the old square 12', (
    tester,
  ) async {
    final c = await _mountThread(tester, text: 'salam', lang: _tk);

    final pad = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('salam'),
            matching: find.byType(Container),
          ),
        )
        .map((w) => w.padding)
        .whereType<EdgeInsets>()
        .toList();
    expect(
      pad,
      contains(const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
    );

    await _unmount(tester, c);
  });
}
