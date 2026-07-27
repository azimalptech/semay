/// Compact count formatting used on every like/view/send/share/comment counter:
/// 1..999 as-is, thousands as `1.2K`, millions as `3.4M` (one decimal, trailing
/// `.0` stripped so it reads `12K`, not `12.0K`). Billions fall through to `M`
/// intentionally — this app's counters never approach 1e9, and an extra `B`
/// tier would just be dead code.
String formatCount(int n) {
  if (n < 0) return '0';
  if (n < 1000) return '$n';
  if (n < 1000000) return '${_trim(n / 1000)}K';
  return '${_trim(n / 1000000)}M';
}

String _trim(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
