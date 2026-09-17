// The owner's report: "Font size inside chat is very small, make it close to
// instagram and whatsapp." Chat was drawing message bodies at AppTypography's
// bodyMedium (15) and every secondary line at caption (11); both messengers
// run ~16 message text, ~12 timestamps, and a ~14 inbox preview under a ~17
// name.
//
// These tests pin the NEW sizes on the real widgets — read off the rendered
// RenderParagraph, not off a constant — and, just as importantly, pin the two
// things that made a blanket bump the wrong fix:
//
//  1. the scale is chat-scoped (ChatTypography), so AppTypography's app-wide
//     body scale is untouched and no approved screen resizes;
//  2. nothing clips at the new sizes with real Turkmen strings, including at a
//     raised platform text scale — sizes stay plain fontSizes, so the
//     accessibility setting still works.

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
import 'package:semay/core/theme.dart';
import 'package:semay/features/chat/chat_list_screen.dart';
import 'package:semay/features/chat/chat_providers.dart';
import 'package:semay/features/chat/chat_thread_screen.dart';
import 'package:semay/features/store_profile/store_profile_providers.dart';
import 'package:semay/services/auth_service.dart';

import '../support/fake_realtime.dart';

const _chatId = 'u1_s1';
const _s = S(false);
const _tick = Duration(milliseconds: 10);

/// A real Turkmen shop name of the length that actually shows up in this
/// product — the case that has to survive a 17 px name beside a timestamp.
const _longName = 'Aşgabat Söwda Merkezi Egin-eşik we Aýakgap Dükany';
const _longPreview =
    'Salam, sargydyňyz taýýar boldy, ertir sagat onda alyp bilersiňiz';

/// The font size the renderer actually resolved for [finder]'s text — not the
/// TextStyle the widget was handed, so a DefaultTextStyle merge or a copyWith
/// that dropped the size would fail this.
double _renderedSize(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  return paragraph.text.style!.fontSize!;
}

double? _renderedHeight(WidgetTester tester, Finder finder) =>
    tester.renderObject<RenderParagraph>(finder).text.style!.height;

// ---------------------------------------------------------------- the thread

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

Future<ProviderContainer> _mountThread(
  WidgetTester tester, {
  required String text,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  stubConnectivity();
  final connector = FakeConnector();
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(_s),
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
          'name': 'Shop',
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
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: textScaler),
          child: const ChatThreadScreen(chatId: _chatId),
        ),
      ),
    ),
  );
  await tester.pump(_tick);
  return container;
}

/// The thread owns a 1-second staleness ticker, a realtime subscription and a
/// setActiveChat debounce; flutter_test fails a test that ends with any of
/// them pending, so every thread test tears the tree down explicitly rather
/// than in an addTearDown (which runs too late for that check).
Future<void> _unmountThread(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
}

// ----------------------------------------------------------------- the inbox

ChatDoc _chat({required String preview}) => ChatDoc({
  'id': _chatId,
  'userId': 'u1',
  'storeId': 's1',
  'lastMessageText': preview,
  'lastMessageAt': DateTime.now().toUtc().toIso8601String(),
  'unreadByUser': 0,
  'unreadByAdmin': 0,
});

Future<void> _mountInbox(
  WidgetTester tester, {
  required String storeName,
  required String preview,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  final container = ProviderContainer(
    overrides: [
      l10nProvider.overrideWithValue(_s),
      appRoleProvider.overrideWith((ref) async => AppRole.user),
      realtimeConnectionProvider.overrideWith(
        (ref) => Stream.value(RealtimeConnectionState.connected),
      ),
      userChatsProvider.overrideWith(
        (ref) => Stream.value([_chat(preview: preview)]),
      ),
      activeStoresProvider.overrideWith((ref) async => const <ChatDoc>[]),
      storeDocProvider.overrideWith(
        (ref, id) =>
            Stream.value({'id': id, 'name': storeName, 'avatarUrl': ''}),
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
          data: MediaQueryData(textScaler: textScaler),
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

/// A real phone, so "does it fit on one row" means something.
void _phoneSized(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532); // iPhone 13, 3x
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  group('the conversation reads at messenger scale', () {
    testWidgets('the message body is 16 with a generous line height', (
      tester,
    ) async {
      final c = await _mountThread(tester, text: 'salam');

      final body = find.text('salam');
      expect(
        _renderedSize(tester, body),
        16,
        reason:
            'WhatsApp/Instagram message text; was 15 (AppTypography.bodyMedium)',
      );
      // Instagram's messages read large as much from the leading as the glyph
      // size — the height is part of the fix, not decoration.
      expect(_renderedHeight(tester, body), 1.3);

      await _unmountThread(tester, c);
    });

    testWidgets('the clock under a bubble is 12, not 11', (tester) async {
      final c = await _mountThread(tester, text: 'salam');

      final clock = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
      expect(clock, findsOneWidget);
      expect(_renderedSize(tester, clock), 12);

      await _unmountThread(tester, c);
    });

    testWidgets('the Sending/Sent/Seen status line is 12', (tester) async {
      final c = await _mountThread(tester, text: 'salam');

      final line = find.descendant(
        of: find.byType(MessageStatusLine),
        matching: find.byType(Text),
      );
      expect(find.text(_s.sendingStatus), findsOneWidget);
      expect(_renderedSize(tester, line), 12);

      await _unmountThread(tester, c);
    });

    testWidgets('the composer types and hints at 16', (tester) async {
      final c = await _mountThread(tester, text: 'salam');

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.style!.fontSize, 16);
      expect(field.decoration!.hintStyle!.fontSize, 16);

      await _unmountThread(tester, c);
    });

    testWidgets('a long Turkmen message does not overflow its bubble', (
      tester,
    ) async {
      _phoneSized(tester);
      final c = await _mountThread(tester, text: _longPreview);
      await tester.pump(_tick);

      expect(find.text(_longPreview), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _unmountThread(tester, c);
    });
  });

  group('the inbox row reads at messenger scale', () {
    testWidgets('name 17, preview 14, time 12', (tester) async {
      _phoneSized(tester);
      await _mountInbox(tester, storeName: 'Shop', preview: 'öňki habar');

      expect(
        _renderedSize(tester, find.text('Shop')),
        17,
        reason: 'was 15 (AppTypography.bodyMediumSemibold)',
      );
      expect(
        _renderedSize(tester, find.text('öňki habar')),
        14,
        reason: 'was 11 (AppTypography.caption)',
      );
      expect(
        _renderedSize(tester, find.text(_s.today)),
        12,
        reason: 'was 11 (AppTypography.caption)',
      );
    });

    testWidgets('"ýazýar…" takes the preview line at the preview size', (
      tester,
    ) async {
      _phoneSized(tester);
      await _mountInbox(tester, storeName: 'Shop', preview: 'öňki habar');
      // No typing stamp in this fixture, so the preview itself is the line;
      // both branches of _RowSubtitle must share one size, which is what
      // makes the row stop resizing when they start typing.
      expect(
        ChatTypography.inboxPreview.fontSize,
        14,
        reason: 'the typing branch copyWiths this same style',
      );
      expect(_renderedSize(tester, find.text('öňki habar')), 14);
    });

    testWidgets(
      'a long Turkmen store name plus a timestamp fits the row: no overflow, '
      'name ellipsized on one line',
      (tester) async {
        _phoneSized(tester);
        await _mountInbox(
          tester,
          storeName: _longName,
          preview: _longPreview,
        );

        expect(tester.takeException(), isNull);

        final name = tester.widget<Text>(find.text(_longName));
        expect(name.maxLines, 1);
        expect(name.overflow, TextOverflow.ellipsis);
        // The timestamp keeps its own place on the preview line rather than
        // being pushed off it.
        expect(find.text(_s.today), findsOneWidget);
      },
    );

    testWidgets(
      'and still fits at a 1.3 platform text scale — sizes are not hard-coded '
      'in a way that defeats the accessibility setting',
      (tester) async {
        _phoneSized(tester);
        await _mountInbox(
          tester,
          storeName: _longName,
          preview: _longPreview,
          textScaler: const TextScaler.linear(1.3),
        );

        expect(tester.takeException(), isNull);
        // The declared size is unchanged; the scaler multiplies it at paint
        // time. A layout that had baked 17 * 1.3 into a box would fail above.
        expect(_renderedSize(tester, find.text(_longName)), 17);
      },
    );
  });

  // The whole reason for a separate class. bodyMedium/bodySmall/caption are the
  // Figma body scale for the feed, profile, orders, leaderboard and settings —
  // screens the owner has already approved and did not ask to resize.
  test('the app-wide scale is untouched: only chat grew', () {
    expect(AppTypography.bodyMedium.fontSize, 15);
    expect(AppTypography.bodyMediumSemibold.fontSize, 15);
    expect(AppTypography.bodySmall.fontSize, 13);
    expect(AppTypography.caption.fontSize, 11);

    expect(ChatTypography.message.fontSize, 16);
    expect(ChatTypography.bubbleTime.fontSize, 12);
    expect(ChatTypography.status.fontSize, 12);
    expect(ChatTypography.composer.fontSize, 16);
    expect(ChatTypography.inboxName.fontSize, 17);
    expect(ChatTypography.inboxPreview.fontSize, 14);
    expect(ChatTypography.inboxTime.fontSize, 12);
  });
}
