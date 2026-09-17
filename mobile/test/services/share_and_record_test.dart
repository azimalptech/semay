// Drives the REAL PostsService.shareAndRecord through the REAL share_plus
// method-channel implementation, intercepting the platform channel exactly
// where Share.kt / FPPSharePlusPlugin.m would receive it. Pins (1) what the
// OS sheet gets — the public https link inside `text`, a title, and never a
// `uri` (share_plus drops text whenever uri is set, and the old bare
// `semay://post/<id>` reached recipients as an inert string) — and (2) when
// recordShare fires: only for a completed share, exactly once.

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus_platform_interface/method_channel/method_channel_share.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:semay/core/api_client.dart';
import 'package:semay/core/interaction_buffer.dart';
import 'package:semay/core/l10n.dart';
import 'package:semay/core/outbox.dart';
import 'package:semay/features/shared/post_interaction_providers.dart';
import 'package:semay/features/store_profile/store_profile_screen.dart';
import 'package:semay/services/auth_service.dart';
import 'package:semay/services/posts_service.dart';

const _postId = 'POST123';
const _storeId = 'e8fa0956-2dc3-4234-9445-4428a5bf2f76';
const _headline = 'Aýna — SeMay-de post';
// share_plus's "no app could take it" sentinel (pre-API-22 Android).
const _unavailable = 'dev.fluttercommunity.plus/share/unavailable';

class _RecordingBuffer extends InteractionBuffer {
  _RecordingBuffer() : super(ApiClient(Dio()));

  final recorded = <(String, InteractionKind)>[];

  @override
  Future<void> record(String postId, InteractionKind kind) async {
    recorded.add((postId, kind));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late String nativeResult;
  late _RecordingBuffer buffer;
  late PostsService service;

  setUp(() {
    calls = [];
    nativeResult = '';
    // The implementation iOS/Android use. The Windows test host's registrant
    // would otherwise install the mailto: fallback plugin.
    SharePlatform.instance = MethodChannelShare();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
          calls.add(call);
          return nativeResult;
        });
    buffer = _RecordingBuffer();
    service = PostsService(
      ApiClient(Dio()),
      OutboxService(
        ApiClient(Dio()),
        Connectivity(),
        hasSession: () => false,
        uploader:
            ({
              required folder,
              required bytes,
              required fileExt,
              required contentType,
            }) async => '',
      ),
      buffer,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, null);
  });

  Map<String, dynamic> shareArgs() {
    expect(calls, hasLength(1));
    expect(calls.single.method, 'share');
    return Map<String, dynamic>.from(calls.single.arguments as Map);
  }

  test('the sheet gets the https post link as text with a title, no uri', () async {
    await service.shareAndRecord(
      _postId,
      isReel: false,
      headline: _headline,
      caption: 'Täze köýnek',
    );
    final args = shareArgs();
    expect(args['text'], contains('https://semaycollection.com/p/$_postId'));
    expect(args['text'], startsWith('$_headline\n'));
    expect(args['text'], contains('\nTäze köýnek\n'));
    expect(args['title'], _headline);
    expect(args['subject'], _headline);
    expect(args.containsKey('uri'), isFalse);
    expect(args.containsKey('originX'), isFalse);
  });

  test('a reel shares the /r/ link', () async {
    await service.shareAndRecord(_postId, isReel: true, headline: _headline);
    final args = shareArgs();
    expect(args['text'], endsWith('\nhttps://semaycollection.com/r/$_postId'));
    expect(args['text'], isNot(contains('/p/')));
  });

  test('the button rect travels as the sheet origin (iPad popover anchor)', () async {
    await service.shareAndRecord(
      _postId,
      isReel: false,
      headline: _headline,
      sharePositionOrigin: const Rect.fromLTWH(10, 20, 30, 40),
    );
    final args = shareArgs();
    expect(args['originX'], 10);
    expect(args['originY'], 20);
    expect(args['originWidth'], 30);
    expect(args['originHeight'], 40);
  });

  test('a dismissed sheet ("") is `dismissed`, not counted, and stays silent', () async {
    // Dismissed, NOT failed: the user saw the sheet and backed out on
    // purpose, so the UI must say nothing (showShareOutcome).
    nativeResult = '';
    final outcome = await service.shareAndRecord(
      _postId,
      isReel: false,
      headline: _headline,
    );
    expect(outcome, ShareOutcome.dismissed);
    expect(buffer.recorded, isEmpty);
  });

  test('a chosen target (com.whatsapp) is counted exactly once', () async {
    nativeResult = 'com.whatsapp';
    final outcome = await service.shareAndRecord(
      _postId,
      isReel: false,
      headline: _headline,
    );
    expect(outcome, ShareOutcome.shared);
    expect(buffer.recorded, [(_postId, InteractionKind.share)]);
  });

  test('the unavailable sentinel is not counted', () async {
    nativeResult = _unavailable;
    final outcome = await service.shareAndRecord(
      _postId,
      isReel: true,
      headline: _headline,
    );
    expect(outcome, ShareOutcome.dismissed);
    expect(buffer.recorded, isEmpty);
  });

  test('a plugin failure degrades to "not shared" instead of escaping the tap', () async {
    // The reachable case this guards: on iPad share_plus raises when
    // sharePositionOrigin is null, which shareOriginOf can legitimately
    // return. Every caller is an onPressed, so a throw would surface as an
    // unhandled async error with no UI at all.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
          calls.add(call);
          throw PlatformException(code: 'Unavailable', message: 'no popover anchor');
        });
    final outcome = await service.shareAndRecord(
      _postId,
      isReel: false,
      headline: _headline,
    );
    // `failed`, not `dismissed`: the sheet never appeared, so the button
    // looked like it did nothing and the user has to be told.
    expect(outcome, ShareOutcome.failed);
    expect(buffer.recorded, isEmpty);
  });

  // The store funnel is a SEPARATE code path (store_profile_screen.dart
  // shareStore, reached from the visitor's app-bar icon and the owner's
  // "Share" pill) that builds its own ShareParams. It carries no counter, so
  // a regression there would be completely silent.
  testWidgets('a store share sends the /s/ link with a title and no uri', (tester) async {
    late BuildContext capturedContext;
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProfileProvider.overrideWith((ref) async => {'name': 'T', 'language': 'tk'}),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              capturedContext = context;
              capturedRef = ref;
              return const SizedBox(width: 40, height: 20);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await shareStore(
      capturedContext,
      capturedRef,
      storeId: _storeId,
      storeName: 'Aýna',
    );

    final args = shareArgs();
    final headline = S(false).shareStoreHeadline('Aýna');
    expect(args['text'], '$headline\nhttps://semaycollection.com/s/$_storeId');
    expect(args['title'], headline);
    expect(args['subject'], headline);
    expect(args.containsKey('uri'), isFalse);
    // The iPad popover anchor travels — the widget above has a real size.
    expect(args['originWidth'], isNotNull);
    // Stores have no share counter (docs/02), so nothing is recorded.
    expect(buffer.recorded, isEmpty);
  });

  testWidgets('a failing store share does not escape the tap', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
          throw PlatformException(code: 'Unavailable');
        });
    final h = await _pumpShareHost(tester);
    await expectLater(
      shareStore(h.context, h.ref, storeId: _storeId, storeName: 'Aýna'),
      completes,
    );
  });

  // The user-visible half. The store icon and the post/reel icon are the same
  // glyph on adjacent screens, and only the post one used to report back: a
  // store share confirmed nothing on success, and on a sheet that could not be
  // presented at all (the iPad no-anchor case, which shareOriginOf explicitly
  // allows) it showed no message anywhere — a Share button that did literally
  // nothing.
  group('every share button reports back to the user', () {
    testWidgets('store share confirms with the same snackbar as a post share',
        (tester) async {
      nativeResult = 'com.whatsapp';
      final h = await _pumpShareHost(tester);
      await shareStore(h.context, h.ref, storeId: _storeId, storeName: 'Aýna');
      await tester.pump();
      expect(find.text(S(false).postShared), findsOneWidget);
    });

    testWidgets('a dismissed store share stays silent — it was deliberate',
        (tester) async {
      nativeResult = '';
      final h = await _pumpShareHost(tester);
      await shareStore(h.context, h.ref, storeId: _storeId, storeName: 'Aýna');
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a store sheet that never opened says so, naming the reason',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
            throw PlatformException(code: 'Unavailable', message: 'no popover anchor');
          });
      final h = await _pumpShareHost(tester);
      await shareStore(h.context, h.ref, storeId: _storeId, storeName: 'Aýna');
      await tester.pump();
      expect(find.text(S(false).shareFailed), findsOneWidget);
    });

    testWidgets('a post sheet that never opened says the same thing, in Russian',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannelShare.channel, (call) async {
            throw PlatformException(code: 'Unavailable');
          });
      final h = await _pumpShareHost(tester, language: 'ru');
      await shareAndNotify(
        h.context,
        h.ref,
        _postId,
        isReel: false,
        storeName: 'Aýna',
      );
      await tester.pump();
      expect(find.text(S(true).shareFailed), findsOneWidget);
      // Both languages exist and differ — no English, no fallthrough.
      expect(S(true).shareFailed, isNot(S(false).shareFailed));
    });
  });
}

typedef _ShareHost = ({BuildContext context, WidgetRef ref});

/// A Scaffold under a ProviderScope, so ScaffoldMessenger has somewhere to put
/// a SnackBar, plus the context/ref both share entry points take.
Future<_ShareHost> _pumpShareHost(
  WidgetTester tester, {
  String language = 'tk',
}) async {
  late BuildContext ctx;
  late WidgetRef wref;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userProfileProvider.overrideWith(
          (ref) async => {'name': 'T', 'language': language},
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              ctx = context;
              wref = ref;
              // Watched, not merely read later: l10nProvider follows the async
              // userProfileProvider, and with nothing listening it would stay
              // on its Turkmen default forever and every language assertion
              // below would pass vacuously.
              ref.watch(l10nProvider);
              return const SizedBox(width: 40, height: 20);
            },
          ),
        ),
      ),
    ),
  );
  // userProfileProvider is async, and l10nProvider follows it — pump until the
  // override has landed, or every assertion would silently read Turkmen.
  await tester.pump();
  await tester.pump();
  expect(
    wref.read(l10nProvider).isRu,
    language == 'ru',
    reason: 'l10n did not settle on "$language"',
  );
  return (context: ctx, ref: wref);
}
