import 'package:flutter/widgets.dart';

import 'api_client.dart';

/// The hosts the OS hands the app links for — the AndroidManifest https
/// intent-filter and the AASA name exactly these. Accepted regardless of
/// API_BASE_URL: a dev build tapped on a production link should still open it.
const shareHosts = {'semaycollection.com', 'www.semaycollection.com'};

/// Explicit override for the origin every shared link is built from. Only
/// needed if the share pages ever move off [shareHosts] (a second brand, a
/// staging domain) — and then the AndroidManifest filter and the server's
/// AASA have to name that host too.
const _shareSiteOriginOverride = String.fromEnvironment('SHARE_SITE_ORIGIN');

/// Where the public share pages live (server/src/share/routes.ts).
///
/// Deliberately NOT just `Uri.parse(apiBaseUrl).origin`. A link is consumed on
/// someone else's phone, by an OS that only recognises [shareHosts], so the
/// API origin is the right source only when it IS one of those hosts. A build
/// made without `--dart-define=API_BASE_URL` (every debug build, and any
/// mis-built release) would otherwise hand recipients
/// `http://localhost:8080/p/<id>` — not https, not reachable, not an App Link,
/// and nothing would flag it because the share sheet looks identical.
final String siteOrigin = _resolveSiteOrigin();

String _resolveSiteOrigin() {
  if (_shareSiteOriginOverride.isNotEmpty) return _shareSiteOriginOverride;
  final api = Uri.tryParse(apiBaseUrl);
  if (api != null && shareHosts.contains(api.host.toLowerCase())) {
    return api.origin;
  }
  return 'https://semaycollection.com';
}

/// Custom-scheme mirror of the https links: `semay://open/p/<id>`. The fixed
/// dummy host is load-bearing. The engine hands go_router the whole URI and
/// go_router matches on `uri.path` alone, so the Phase 1 shape
/// `semay://post/<id>` arrived as `/<id>` (the kind sat in the host) and could
/// never match a route — [parseIncomingLink] still accepts that legacy shape
/// for links already in the wild, but nothing emits it any more.
const shareScheme = 'semay';
const shareSchemeHost = 'open';

String postShareUrl(String postId, {String? origin}) =>
    '${origin ?? siteOrigin}/p/$postId';
String reelShareUrl(String postId, {String? origin}) =>
    '${origin ?? siteOrigin}/r/$postId';
String storeShareUrl(String storeId, {String? origin}) =>
    '${origin ?? siteOrigin}/s/$storeId';

enum ShareTargetKind { post, store }

/// What an incoming link points at, and the in-app route that shows it. A
/// reel link (/r/) resolves to the same post route as an image post: the
/// detail screen already switches to the full-screen player by post type.
class ShareTarget {
  const ShareTarget(this.kind, this.id);

  final ShareTargetKind kind;
  final String id;

  String get route => switch (kind) {
    ShareTargetKind.post => '/post/$id',
    ShareTargetKind.store => '/store/$id',
  };

  @override
  bool operator ==(Object other) =>
      other is ShareTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'ShareTarget($kind, $id)';
}

// Ids are UUIDs on the server; anything else in the slot is a mangled link,
// not a target worth pushing a screen for. The SAME shape server/src/share/
// routes.ts enforces (UUID_RE) — it renders its own localised "Salgy
// tapylmady" page for anything else, and the two halves must agree about
// which links are real or a hand-typed https://semaycollection.com/p/abc123
// would be intercepted by the app (once App Links verify), push a detail
// screen for a post that cannot exist, and show an in-app error state where
// the browser would have explained the link is wrong.
final _idPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// The target of a link the OS opened the app with, or null when the URI is
/// not one of ours. Accepts, case-insensitively:
///   `https://semaycollection.com/p/<id>`, `/r/<id>`, `/s/<id>` (also on
///   www., on whatever host [siteOrigin] resolves to, and on the API's own
///   host so a dev build can be deep-linked at its own server — [siteHost]
///   overrides the latter in tests); `semay://<any host>/p/<id>`, `/r/<id>`,
///   `/s/<id>`; and the legacy `semay://post/<id>`, `semay://store/<id>`.
ShareTarget? parseIncomingLink(Uri uri, {String? siteHost}) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  if (scheme == 'http' || scheme == 'https') {
    final own = (siteHost ?? Uri.tryParse(apiBaseUrl)?.host ?? '').toLowerCase();
    if (host != own && !shareHosts.contains(host)) return null;
    return _fromPath(segments);
  }
  if (scheme == shareScheme) {
    if (host == 'post' || host == 'store') {
      if (segments.length != 1 || !_idPattern.hasMatch(segments.single)) {
        return null;
      }
      return ShareTarget(
        host == 'post' ? ShareTargetKind.post : ShareTargetKind.store,
        segments.single,
      );
    }
    return _fromPath(segments);
  }
  return null;
}

/// Whether the OS handed us this URI because the app CLAIMS it — regardless
/// of whether [parseIncomingLink] could make a target out of it.
///
/// The two are deliberately not the same set, and the gap is what used to
/// strand people. The AndroidManifest autoVerify filter claims every
/// https://semaycollection.com path merely STARTING with /p/, /r/ or /s/, and
/// the custom-scheme filter claims semay:// with no path constraint at all —
/// so `/p/` alone, `/p/<id>/extra`, `/p/<id>.` (a link with trailing prose
/// punctuation), a non-UUID id and `semay://open/x/<id>` are all delivered to
/// the app and all parse to null. Once App Links verify, Android routes them
/// here with no chooser, so they are ordinary traffic, not edge cases.
///
/// router.dart uses this to swallow them: a mangled link must be a no-op,
/// never a navigation. Route information that is genuinely NOT ours (an
/// in-app path pushed over the same platform channel, say) still has to fall
/// through to go_router, which is why this is a host/scheme test and not
/// `true`.
bool isOwnShareUri(Uri uri, {String? siteHost}) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == shareScheme) return true;
  if (scheme != 'http' && scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (shareHosts.contains(host)) return true;
  final own = (siteHost ?? Uri.tryParse(apiBaseUrl)?.host ?? '').toLowerCase();
  return own.isNotEmpty && host == own;
}

ShareTarget? _fromPath(List<String> segments) {
  if (segments.length != 2 || !_idPattern.hasMatch(segments[1])) return null;
  return switch (segments[0].toLowerCase()) {
    'p' || 'r' => ShareTarget(ShareTargetKind.post, segments[1]),
    's' => ShareTarget(ShareTargetKind.store, segments[1]),
    _ => null,
  };
}

/// Body handed to the OS share sheet. The link rides INSIDE the text: share_plus
/// drops `text` whenever `uri` is set, on both platforms (Share.kt puts
/// `uri ?: text` in EXTRA_TEXT, FPPSharePlusPlugin.m shares the bare NSURL and
/// ignores text/title), so a bare `uri` could never carry a title or caption.
/// Headline first, the caption (collapsed, capped) if any, the link last so
/// every receiving app linkifies it.
String shareText({
  required String headline,
  String caption = '',
  required String url,
}) {
  final collapsed = caption.replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = collapsed.length > 200
      ? '${collapsed.substring(0, 200)}…'
      : collapsed;
  return [headline, if (short.isNotEmpty) short, url].join('\n');
}

/// The tapped control's screen rect, for ShareParams.sharePositionOrigin. On
/// iPad the sheet is a popover that has to be anchored to something, and
/// share_plus returns a FlutterError — no sheet at all — when it is missing;
/// every share entry point passes its own button's context here.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
