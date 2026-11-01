/// Spec v2 operators (testdata/flags/README.md, "Spec v2"); port of go/internal/flageval/ops_v2.go.
/// The evaluator passes its own number and version coercions so both agree.
final _rel = RegExp(r'^-?(\d{1,6})([hdwmy])$');
final _rfc3339 = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$');
final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
const _unit = {'h': 3600, 'd': 86400, 'w': 7 * 86400, 'm': 30 * 86400, 'y': 365 * 86400};

const v2Ops = {
  'icontains', 'not_icontains', 'starts_with', 'not_starts_with', 'ends_with', 'not_ends_with', //
  'between', 'not_between', 'is_date_before', 'is_date_after', //
  'semver_eq', 'semver_neq', 'semver_gt', 'semver_gte', 'semver_lt', 'semver_lte', //
  'semver_tilde', 'semver_caret', 'semver_wildcard',
};

DateTime? _rfc(String s) => _rfc3339.hasMatch(s) ? DateTime.tryParse(s)?.toUtc() : null;

/// The evaluation clock: `Context.now` (RFC 3339) when it parses, else the wall clock.
DateTime parseNow(Object? s) => (s is String ? _rfc(s) : null) ?? DateTime.now().toUtc();

DateTime? _instant(Object? v, DateTime now, bool rel) {
  if (v is num) return DateTime.fromMicrosecondsSinceEpoch((v * 1e6).round(), isUtc: true);
  if (v is! String) return null;
  final s = v.trim();
  if (rel) {
    final m = _rel.firstMatch(s);
    if (m != null) return now.subtract(Duration(seconds: int.parse(m.group(1)!) * _unit[m.group(2)!]!));
  }
  final t = _rfc(s);
  if (t != null) return t;
  if (_date.hasMatch(s)) {
    final d = DateTime.tryParse('${s}T00:00:00Z');
    // DateTime.parse rolls 2026-02-31 over; a real date round-trips
    if (d != null && d.toIso8601String().startsWith(s)) return d;
  }
  return null;
}

int _cmpParts(List<int> a, List<int> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Half-open [lo, hi) of a tilde, caret or wildcard value.
(List<int>, List<int>)? _semverRange(String op, Object? want, List<int>? Function(Object?) parse) {
  if (want is! String) return null;
  var s = want.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final parts = s.split('.');
  if (op == 'semver_wildcard') {
    if (!const {'*', 'x', 'X'}.contains(parts.last)) return null;
    if (parts.length == 1) return ([0], [1 << 30]);
    final lo = parse(parts.sublist(0, parts.length - 1).join('.'));
    if (lo == null) return null;
    return (lo, [...lo.sublist(0, lo.length - 1), lo.last + 1]);
  }
  final p = parse(want);
  if (p == null) return null;
  final q = [...p, ...List.filled(p.length < 3 ? 3 - p.length : 0, 0)];
  final (a, b, c) = (q[0], q[1], q[2]);
  final List<int> hi;
  if (op == 'semver_tilde' && parts.length == 1) {
    hi = [a + 1, 0, 0];
  } else if (op == 'semver_tilde' || (a == 0 && b > 0)) {
    hi = [a, b + 1, 0];
  } else if (a > 0) {
    hi = [a + 1, 0, 0];
  } else {
    hi = [0, 0, c + 1];
  }
  return (q, hi);
}

/// Applies a v2 operator to a set property. Unknown operators never match.
bool matchV2(
  String op,
  Object? prop,
  Object? want,
  DateTime now,
  double? Function(Object?) toFloat,
  List<int>? Function(Object?) parse,
  int? Function(Object?, Object?) cmpSemver,
) {
  switch (op) {
    case 'icontains':
    case 'not_icontains':
    case 'starts_with':
    case 'not_starts_with':
    case 'ends_with':
    case 'not_ends_with':
      if (prop is! String || want is! String) return false;
      if (op.endsWith('icontains')) return prop.toLowerCase().contains(want.toLowerCase()) == (op == 'icontains');
      if (op.endsWith('starts_with')) return prop.startsWith(want) == (op == 'starts_with');
      return prop.endsWith(want) == (op == 'ends_with');
    case 'between':
    case 'not_between':
      final x = toFloat(prop);
      if (x == null || want is! List || want.length != 2 || want[0] is! num || want[1] is! num) return false;
      return (x >= (want[0] as num) && x <= (want[1] as num)) == (op == 'between');
    case 'is_date_before':
    case 'is_date_after':
      final p = _instant(prop, now, false);
      final w = _instant(want, now, true);
      if (p == null || w == null) return false;
      return op == 'is_date_before' ? p.isBefore(w) : p.isAfter(w);
    case 'semver_tilde':
    case 'semver_caret':
    case 'semver_wildcard':
      final v = parse(prop);
      final r = _semverRange(op, want, parse);
      return v != null && r != null && _cmpParts(v, r.$1) >= 0 && _cmpParts(v, r.$2) < 0;
    case 'semver_eq':
    case 'semver_neq':
    case 'semver_gt':
    case 'semver_gte':
    case 'semver_lt':
    case 'semver_lte':
      final c = cmpSemver(prop, want);
      if (c == null) return false;
      return switch (op) {
        'semver_eq' => c == 0,
        'semver_neq' => c != 0,
        'semver_gt' => c > 0,
        'semver_gte' => c >= 0,
        'semver_lt' => c < 0,
        _ => c <= 0,
      };
  }
  return false;
}
