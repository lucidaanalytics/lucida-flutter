import 'flag_ops_v2.dart';

/// Operator semantics: port of go/internal/flageval/ops.go (the reference).
final _num = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

double? _toFloat(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String && _num.hasMatch(v.trim())) return double.parse(v.trim());
  return null;
}

/// Numbers compare numerically; a number never equals a string.
bool _equal(Object? a, Object? b) {
  if (a is num || b is num) return a is num && b is num && a == b;
  return a == b;
}

List<int>? _parseVersion(Object? v) {
  if (v is! String) return null;
  var s = v.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final i = s.indexOf(RegExp(r'[-+]'));
  if (i >= 0) s = s.substring(0, i);
  final out = <int>[];
  for (final p in s.split('.')) {
    if (!RegExp(r'^[+-]?\d+$').hasMatch(p)) return null;
    final n = int.parse(p);
    if (n < 0) return null;
    out.add(n);
  }
  return out;
}

int? _cmpVersion(Object? a, Object? b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  if (pa == null || pb == null) return null;
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Missing/null properties match only is_not_set; every other op (even negations) is false.
bool matchOp(String op, Object? prop, bool present, Object? want, bool semver, [DateTime? now]) {
  final isSet = present && prop != null;
  if (op == 'is_set') return isSet;
  if (op == 'is_not_set') return !isSet;
  if (!isSet) return false;
  switch (op) {
    case 'eq':
    case 'neq':
      bool eq;
      if (semver) {
        final c = _cmpVersion(prop, want);
        if (c == null) return false;
        eq = c == 0;
      } else {
        eq = _equal(prop, want);
      }
      return eq == (op == 'eq');
    case 'contains':
    case 'ncontains':
    case 'regex':
    case 'nregex':
      if (prop is! String || want is! String) return false;
      if (op == 'contains' || op == 'ncontains') return prop.contains(want) == (op == 'contains');
      RegExp re;
      try {
        re = RegExp(want);
      } catch (_) {
        return false; // an invalid pattern never matches, even for nregex
      }
      return re.hasMatch(prop) == (op == 'regex');
    case 'gt':
    case 'gte':
    case 'lt':
    case 'lte':
      int? c;
      if (semver) {
        c = _cmpVersion(prop, want);
      } else {
        final a = _toFloat(prop);
        final b = _toFloat(want);
        c = a == null || b == null ? null : a.compareTo(b);
      }
      if (c == null) return false;
      return op == 'gt'
          ? c > 0
          : op == 'gte'
              ? c >= 0
              : op == 'lt'
                  ? c < 0
                  : c <= 0;
    case 'in':
    case 'not_in':
      if (want is! List) return false;
      return want.any((w) => _equal(prop, w)) == (op == 'in');
  }
  return matchV2(op, prop, want, now ?? DateTime.now().toUtc(), _toFloat, _parseVersion, _cmpVersion);
}
