import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'flag_ops.dart';
import 'flag_ops_v2.dart';

/// Port of go/internal/flageval (the reference) over the JSON wire shapes of testdata/flags.
/// Flags, contexts and results are plain maps so shared vectors load directly.
typedef Json = Map<String, dynamic>;

final double _scale = 4503599627370496.0; // 16^13

/// Hash in [0,1): first 13 hex chars of sha256 / 16^13.
double flagHash(String flagKey, String salt, String bucketingKey, {bool variant = false}) {
  return hashInput(variant ? '$flagKey.$salt.variant.$bucketingKey' : '$flagKey.$salt.$bucketingKey');
}

/// Hash of a raw `key.salt.unit` string (pinned by hash_vectors).
double hashInput(String s) => int.parse(sha256.convert(utf8.encode(s)).toString().substring(0, 13), radix: 16) / _scale;

Json _off(String reason, [int idx = -1]) => {'value': false, 'reason': reason, 'condition_index': idx};

bool _valueMatches(Object? got, Object? want) {
  if (want is bool) return got is bool ? got == want : want; // variant string = "on"
  return got == want;
}

bool _filterMatches(Json f, Json c, Map<String, Json> resolved) {
  final key = f['key'] as String;
  final now = parseNow(c['now']);
  Json? bag;
  switch (f['type']) {
    case 'person':
      bag = c['person_properties'] as Json?;
    case 'group':
      bag = (c['group_properties'] as Json?)?[f['group_type'] ?? ''] as Json?;
    case 'device':
      bag = c['device_properties'] as Json?;
    case 'geo':
      bag = c['geo_properties'] as Json?;
    case 'app_version':
      final v = c['app_version'];
      return matchOp(f['op'] as String, v, v != null && v != '', f['value'], true, now);
    case 'flag':
      final r = resolved[key];
      return r != null && matchOp(f['op'] as String, r['value'], true, f['value'], false, now);
    default:
      return false;
  }
  return matchOp(f['op'] as String, bag?[key], bag != null && bag.containsKey(key), f['value'], false, now);
}

Json _pickVariant(Json f, Json cond, String key) {
  final vs = (f['variants'] as List).cast<Json>();
  final over = cond['variant_override'];
  if (over != null) {
    for (final v in vs) {
      if (v['key'] == over) return v;
    }
  }
  final h = flagHash(f['key'] as String, f['salt'] as String, key, variant: true) * 100;
  var cum = 0.0;
  for (final v in vs) {
    cum += (v['rollout_pct'] as num).toDouble();
    if (h < cum) return v;
  }
  return vs.last; // totals < 100: the last variant takes the remainder
}

/// A stored value of a sticky flag decides once a condition's filters passed (LC-EXT-29).
Json? _sticky(Json f, Json cond, int i, Json c) {
  final stored = (c['sticky_assignments'] as Json?)?[f['key']];
  if (f['sticky'] != true || stored == null) return null;
  final res = <String, dynamic>{'value': true, 'reason': 'sticky_bucket', 'condition_index': i};
  final variants = (f['variants'] as List?)?.cast<Json>();
  if (f['type'] == 'multivariate' && variants != null && variants.isNotEmpty) {
    if (variants.any((v) => v['key'] == cond['variant_override'])) return null; // the override wins
    final v = variants.where((x) => stored is String && x['key'] == stored).firstOrNull;
    if (v == null) return null;
    res['value'] = res['variant'] = v['key'];
    if (v['payload'] != null) res['payload'] = v['payload'];
    return res;
  }
  if (stored != true) return null;
  if (f['type'] == 'json' && f['payload'] != null) res['payload'] = f['payload'];
  return res;
}

/// The bucketing unit of an aggregation (a flag's, or one condition's own); null when absent.
String? _unitKey(Json agg, Json c) {
  switch (agg['kind']) {
    case 'group':
      return (c['groups'] as Json?)?[agg['group_type'] ?? ''] as String?;
    case 'device':
      return c['device_id'] as String?;
    default:
      final b = c['bucketing_key'] as String?;
      return (b != null && b.isNotEmpty) ? b : c['distinct_id'] as String?;
  }
}

/// A flag scoped to app contexts is dropped when the request declares contexts and shares none.
bool _appContextAllowed(Json f, Json c) {
  final want = (f['app_contexts'] as List?) ?? const [];
  final have = (c['app_contexts'] as List?) ?? const [];
  return want.isEmpty || have.isEmpty || want.any(have.contains);
}

/// Evaluate one flag; prerequisites and `flag` filters read [resolved] (see [evaluateAll]).
Json evaluateFlag(Json f, Json c, [Map<String, Json> resolved = const {}]) {
  if (!_appContextAllowed(f, c)) return _off('app_context_excluded');
  if (f['active'] != true) return _off('inactive');
  if (f['kill_switch'] == true) return _off('kill_switch');
  var server = false;
  for (final p in (f['prerequisites'] as List? ?? const []).cast<Json>()) {
    final r = resolved[p['flag']];
    if (r == null) return _off('prerequisite_missing');
    if (r['reason'] == 'requires_server') {
      server = true;
    } else if (r['reason'] == 'prerequisite_cycle' || !_valueMatches(r['value'], p['value'])) {
      return _off('prerequisite_failed');
    }
  }
  if (server) return _off('requires_server');
  final key = _unitKey(f['aggregation'] as Json, c);
  final conds = (f['conditions'] as List).cast<Json>();
  final perCondition = conds.any((cd) => cd['aggregation'] != null);
  if ((key == null || key.isEmpty) && (!perCondition || f['holdout'] != null || f['namespace'] != null)) {
    return _off('no_bucketing_key');
  }
  final ho = f['holdout'] as Json?;
  if (ho != null && flagHash('holdout', ho['salt'] as String, key!) * 100 < (ho['percentage'] as num))
    return _off('holdout');
  final ns = f['namespace'] as Json?;
  if (ns != null && (ns['total'] as num) > 0) {
    final b = (flagHash('namespace', ns['salt'] as String, key!) * (ns['total'] as num)).floor();
    if (b < (ns['start'] as num) || b >= (ns['end'] as num)) return _off('namespace_excluded');
  }
  var skipped = 0;
  for (var i = 0; i < conds.length; i++) {
    final cond = conds[i];
    final own = cond['aggregation'] as Json?;
    final ckey = own == null ? key : _unitKey(own, c);
    if (ckey == null || ckey.isEmpty) {
      skipped++;
      continue;
    }
    var cohort = false;
    var ok = true;
    for (final fl in (cond['filters'] as List? ?? const []).cast<Json>()) {
      if (fl['type'] == 'cohort' || (fl['type'] == 'flag' && resolved[fl['key']]?['reason'] == 'requires_server')) {
        cohort = true;
      } else if (!_filterMatches(fl, c, resolved)) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    if (cohort) return _off('requires_server', i);
    final sticky = own == null ? _sticky(f, cond, i, c) : null; // the store keys on the flag-level unit
    if (sticky != null) return sticky;
    if (flagHash(f['key'] as String, f['salt'] as String, ckey) * 100 >= (cond['rollout_pct'] as num)) {
      if (f['early_exit'] == true) return _off('out_of_rollout', i);
      continue;
    }
    final res = <String, dynamic>{'value': true, 'reason': 'condition_match', 'condition_index': i};
    final variants = f['variants'] as List?;
    if (f['type'] == 'multivariate' && variants != null && variants.isNotEmpty) {
      final v = _pickVariant(f, cond, ckey);
      res['value'] = res['variant'] = v['key'];
      if (v['payload'] != null) res['payload'] = v['payload'];
    } else if (f['type'] == 'json' && f['payload'] != null) {
      res['payload'] = f['payload'];
    }
    return res;
  }
  return _off(conds.isNotEmpty && skipped == conds.length ? 'no_bucketing_key' : 'no_condition_match');
}

List<String> _deps(Json f) => [
      for (final p in (f['prerequisites'] as List? ?? const []).cast<Json>()) p['flag'] as String,
      for (final c in (f['conditions'] as List).cast<Json>())
        for (final x in (c['filters'] as List? ?? const []).cast<Json>())
          if (x['type'] == 'flag') x['key'] as String,
    ];

/// Evaluate all flags, resolving prerequisites depth-first; cycles get prerequisite_cycle.
Map<String, Json> evaluateAll(List<Json> flags, Json c) {
  final byKey = {for (final f in flags) f['key'] as String: f};
  final out = <String, Json>{};
  final state = <String, int>{};
  void visit(String key) {
    final f = byKey[key];
    if (f == null || state.containsKey(key)) return;
    state[key] = 1;
    var cyc = false;
    for (final d in _deps(f)) {
      visit(d);
      if (state[d] == 1 || out[d]?['reason'] == 'prerequisite_cycle') cyc = true;
    }
    out[key] = cyc ? _off('prerequisite_cycle') : evaluateFlag(f, c, out);
    state[key] = 2;
  }

  for (final f in flags) {
    visit(f['key'] as String);
  }
  return out;
}

bool requiresServer(Json r) => r['reason'] == 'requires_server';
