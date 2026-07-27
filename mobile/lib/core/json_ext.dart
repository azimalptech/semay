/// Wire-format parsing helpers for the new REST/WS API's JSON shape (see
/// docs/07_MIGRATION.md Phase 9). Every provider rewritten off Firestore
/// needs these instead of reading `Timestamp`/`num` directly:
/// - Firestore `Timestamp` -> the new API's **ISO-8601 date strings**.
/// - Prisma `Decimal` fields (e.g. `price`) -> **numeric strings**, not raw
///   numbers — confirmed live against the real server (`"price":"19.99"`,
///   quoted).
/// `QueryDocumentSnapshot.id` has no equivalent either — every response now
/// carries its own `id` as a field inside the flat map, so `doc.id` call
/// sites become `doc['id']` directly; no helper needed for that one.
library;

/// Thin wrapper over a decoded JSON object that preserves the exact
/// `.id` + `.data()` surface Firestore's `QueryDocumentSnapshot` exposed, so
/// the many screens that read `doc.id` / `doc.data()['field']` need no change
/// when their provider stops returning Firestore snapshots and starts
/// returning REST-decoded maps (the new API always carries `id` as a field
/// inside the flat object — see docs/07_MIGRATION.md Phase 9). Used for both
/// post and store "docs".
class JsonDoc {
  const JsonDoc(this._json);

  final Map<String, dynamic> _json;

  String get id => _json['id'] as String;
  Map<String, dynamic> data() => _json;
}

/// Normalizes a post object from the new API into the shape the existing
/// screens already read. The big one: the API returns `media` as a list of
/// `{url, position, thumbnailUrl}` objects (post_media rows), but every screen
/// still reads the old Firestore `mediaUrls` string array — so synthesize it
/// here once rather than touching ~6 widgets. Also flattens `price` (a decimal
/// string like "19.99" over the wire) to a num. Mutates and returns the map.
Map<String, dynamic> normalizePost(Map<String, dynamic> post) {
  final media = post['media'] as List<dynamic>?;
  if (media != null) {
    post['mediaUrls'] = media
        .map((m) => (m as Map<String, dynamic>)['url'] as String)
        .toList();
  }
  post['mediaUrls'] ??= const <String>[];
  final price = post['price'];
  if (price is String) post['price'] = double.tryParse(price);
  return post;
}

DateTime? parseTimestamp(dynamic value) {
  if (value == null) return null;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

double? parseDecimal(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
