// Share links (docs/04 "Share links"): the one place that builds the public
// https URLs the OS sheet receives and reads the links the OS opens the app
// with. Pins the URL space (/p /r /s on the API origin, no /api/v1), the
// custom-scheme mirror (semay://open/…) and the legacy Phase 1 shapes
// (semay://post/<id>, semay://store/<id>) that are still out in the wild.

import 'package:flutter_test/flutter_test.dart';

import 'package:semay/core/share_links.dart';

const _id = '288fcd06-2cad-4399-9b11-88a9365ad3a0';
const _prod = 'https://semaycollection.com';

void main() {
  group('share URLs', () {
    test('a build with no API_BASE_URL still shares production https links', () {
      // This test runs with apiBaseUrl at its default http://localhost:8080
      // — the state of every debug build and of any release built without
      // the dart-define. The link is consumed on someone ELSE's phone, so it
      // must still be https and on a host the OS recognises; a localhost
      // link would be dead on arrival with nothing to flag it.
      expect(siteOrigin, 'https://semaycollection.com');
      expect(postShareUrl(_id), 'https://semaycollection.com/p/$_id');
      expect(reelShareUrl(_id), 'https://semaycollection.com/r/$_id');
      expect(storeShareUrl(_id), 'https://semaycollection.com/s/$_id');
    });

    test('the emitted origin is always a host the manifest/AASA claim', () {
      // The AndroidManifest autoVerify filter and the server's
      // apple-app-site-association name exactly shareHosts. If siteOrigin
      // could drift off that list, every shared link would silently stop
      // being an App Link with no build error and no runtime symptom.
      expect(shareHosts, contains(Uri.parse(siteOrigin).host));
      expect(Uri.parse(siteOrigin).scheme, 'https');
    });

    test('an explicit origin is used verbatim', () {
      expect(postShareUrl(_id, origin: _prod), '$_prod/p/$_id');
      expect(reelShareUrl(_id, origin: _prod), '$_prod/r/$_id');
      expect(storeShareUrl(_id, origin: _prod), '$_prod/s/$_id');
    });

    test('every built URL parses back to its target', () {
      expect(
        parseIncomingLink(Uri.parse(postShareUrl(_id, origin: _prod))),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(Uri.parse(reelShareUrl(_id, origin: _prod))),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(Uri.parse(storeShareUrl(_id, origin: _prod))),
        const ShareTarget(ShareTargetKind.store, _id),
      );
      // The links this build emits parse back too.
      expect(
        parseIncomingLink(Uri.parse(postShareUrl(_id))),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      // …and so does a link at the API's own origin, so a dev build can be
      // deep-linked at the server it actually talks to.
      expect(
        parseIncomingLink(Uri.parse('http://localhost:8080/p/$_id')),
        const ShareTarget(ShareTargetKind.post, _id),
      );
    });
  });

  group('parseIncomingLink — https', () {
    test('production hosts, with and without www, any case', () {
      for (final host in [
        'semaycollection.com',
        'www.semaycollection.com',
        'SemayCollection.com',
      ]) {
        expect(
          parseIncomingLink(Uri.parse('https://$host/p/$_id')),
          const ShareTarget(ShareTargetKind.post, _id),
          reason: host,
        );
        expect(
          parseIncomingLink(Uri.parse('https://$host/s/$_id')),
          const ShareTarget(ShareTargetKind.store, _id),
          reason: host,
        );
      }
    });

    test('the API origin host (siteHost) is accepted, a foreign host is not', () {
      expect(
        parseIncomingLink(
          Uri.parse('http://10.0.0.5:8080/r/$_id'),
          siteHost: '10.0.0.5',
        ),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(
          Uri.parse('https://evil.example/p/$_id'),
          siteHost: 'localhost',
        ),
        isNull,
      );
    });

    test('unknown paths, missing or malformed ids are not targets', () {
      expect(parseIncomingLink(Uri.parse('$_prod/post/$_id')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/x/$_id')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/p/')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/p')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/p/$_id/extra')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/p/not%20an%20id')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/')), isNull);
      expect(parseIncomingLink(Uri.parse('$_prod/.well-known/x')), isNull);
    });

    test('an id the SERVER would 404 is refused here too', () {
      // server/src/share/routes.ts gates every share path on a strict UUID
      // and renders its own localised "Salgy tapylmady" page for anything
      // else. The app's parser has to agree: once App Links verify, a
      // mangled or hand-typed link is intercepted BY THE APP, so accepting a
      // non-UUID here would push a detail screen for a post that cannot
      // exist — an in-app error state instead of the page that explains the
      // link is wrong. Falling through hands it back to the browser.
      for (final bad in [
        'abc123',
        'not-a-uuid',
        '288fcd06-2cad-4399-9b11-88a9365ad3a', // one hex digit short
        '288fcd062cad439911b88a9365ad3a0', // no dashes
        '288fcd06-2cad-4399-9b11-88a9365ad3a0.', // trailing prose punctuation
      ]) {
        expect(parseIncomingLink(Uri.parse('$_prod/p/$bad')), isNull, reason: bad);
        expect(parseIncomingLink(Uri.parse('semay://open/s/$bad')), isNull, reason: bad);
      }
    });

    test('isOwnShareUri claims everything the OS hands us, parseable or not', () {
      // The manifest's autoVerify pathPrefix and the scheme filter claim a
      // far wider URL space than parseIncomingLink accepts; router.dart uses
      // this predicate to swallow the gap instead of letting go_router reset
      // the stack to an empty "Page Not Found".
      for (final ours in [
        '$_prod/p/',
        '$_prod/p/$_id/extra',
        '$_prod/p/abc123',
        'https://www.semaycollection.com/s/',
        'semay://open/x/$_id',
        'semay://anything',
      ]) {
        expect(isOwnShareUri(Uri.parse(ours)), isTrue, reason: ours);
        // …and every one of them is genuinely unparseable, which is the
        // whole point of the predicate existing separately.
        expect(parseIncomingLink(Uri.parse(ours)), isNull, reason: ours);
      }
      // Route information that is NOT ours must still fall through.
      for (final foreign in ['https://evil.example/p/$_id', '/search', 'tel:+99312345678']) {
        expect(isOwnShareUri(Uri.parse(foreign), siteHost: 'localhost'), isFalse,
            reason: foreign);
      }
      // The API's own host counts as ours, so a dev build can be deep-linked
      // at the server it actually talks to.
      expect(isOwnShareUri(Uri.parse('http://10.0.0.5:8080/p/'), siteHost: '10.0.0.5'), isTrue);
    });

    test('a trailing slash or query does not change the target', () {
      expect(
        parseIncomingLink(Uri.parse('$_prod/p/$_id/')),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(Uri.parse('$_prod/s/$_id?utm=x#f')),
        const ShareTarget(ShareTargetKind.store, _id),
      );
    });
  });

  group('parseIncomingLink — semay:// scheme', () {
    test('semay://open/p|r|s/<id> — the path space mirrors https', () {
      expect(
        parseIncomingLink(Uri.parse('semay://open/p/$_id')),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(Uri.parse('semay://open/r/$_id')),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(Uri.parse('semay://open/s/$_id')),
        const ShareTarget(ShareTargetKind.store, _id),
      );
      // The host is a placeholder so the engine forwards "/p/<id>": any host
      // that isn't a legacy kind works.
      expect(
        parseIncomingLink(Uri.parse('SEMAY://anything/p/$_id')),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(parseIncomingLink(Uri.parse('semay://open/x/$_id')), isNull);
    });

    test('legacy semay://post/<id> and semay://store/<id> still resolve', () {
      expect(
        parseIncomingLink(Uri.parse('semay://post/$_id')),
        const ShareTarget(ShareTargetKind.post, _id),
      );
      expect(
        parseIncomingLink(Uri.parse('semay://store/$_id')),
        const ShareTarget(ShareTargetKind.store, _id),
      );
      expect(parseIncomingLink(Uri.parse('semay://post/$_id/x')), isNull);
      expect(parseIncomingLink(Uri.parse('semay://post/')), isNull);
    });

    test('other schemes are ignored', () {
      expect(parseIncomingLink(Uri.parse('tel:+99312345678')), isNull);
      expect(parseIncomingLink(Uri.parse('/p/$_id')), isNull);
      expect(parseIncomingLink(Uri.parse('mailto:a@b.c')), isNull);
    });
  });

  test('targets map to the in-app routes the shell already uses', () {
    expect(const ShareTarget(ShareTargetKind.post, _id).route, '/post/$_id');
    expect(const ShareTarget(ShareTargetKind.store, _id).route, '/store/$_id');
  });

  group('shareText', () {
    test('headline, then caption, then the link on its own last line', () {
      expect(
        shareText(headline: 'Aýna — SeMay-de post', caption: 'Täze köýnek', url: '$_prod/p/$_id'),
        'Aýna — SeMay-de post\nTäze köýnek\n$_prod/p/$_id',
      );
      expect(
        shareText(headline: 'H', url: '$_prod/s/$_id'),
        'H\n$_prod/s/$_id',
      );
    });

    test('caption whitespace is collapsed and long captions are capped', () {
      expect(
        shareText(headline: 'H', caption: '  a \n\n b\t c  ', url: 'u'),
        'H\na b c\nu',
      );
      final long = List.filled(60, 'word').join(' '); // 299 chars
      final text = shareText(headline: 'H', caption: long, url: 'u');
      final lines = text.split('\n');
      expect(lines, hasLength(3));
      expect(lines[1].length, 201); // 200 + the ellipsis
      expect(lines[1], endsWith('…'));
      expect(lines.last, 'u');
    });
  });
}
