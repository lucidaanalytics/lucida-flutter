import 'dart:convert';

import 'core.dart';
import 'flag_eval.dart';
import 'flag_enrich.dart';
import 'flag_options.dart';

/// Feature flags: local evaluation over optional bootstrap definitions, server evaluation
/// (POST /v1/flags) for flags that need it (cohorts) or when no definitions are present.
/// Last response is cached in (gated) storage so cold starts have values offline.
class Flags {
  Flags(this._core,
      {List<Json> definitions = const [],
      this.deviceProperties = const {},
      this.appVersion,
      this.options = const FlagOptions()})
      : _defs = definitions {
    final raw = _core.storage.get(_cacheKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Json;
        _values = Map<String, dynamic>.from(j['values'] as Map);
        _payloads = Map<String, dynamic>.from(j['payloads'] as Map);
      } catch (_) {/* corrupt cache: ignore */}
    }
    if (options.sendFeatureFlags) {
      _core.enricher = (event) => event == '\$snapshot' ? null : flagEventProps(_values);
    }
    // Bootstrap wins over the cache until the first reload replaces it.
    final boot = _core.c.bootstrap;
    if (boot != null) {
      _values = {..._values, ...boot.flags};
      _payloads = {..._payloads, ...boot.payloads};
    }
  }

  static const _cacheKey = 'lc_flags';
  final Core _core;
  List<Json> _defs;
  final Json deviceProperties;
  final String? appVersion;
  final FlagOptions options;
  final Map<String, dynamic> _personProps = {};
  final Map<String, Map<String, dynamic>> _groupProps = {};
  final List<void Function(Map<String, dynamic>)> _listeners = [];
  Map<String, dynamic> _values = {};
  Map<String, dynamic> _payloads = {};
  Map<String, dynamic> _local = {};
  final Map<String, FlagMeta> _meta = {};
  final List<void Function(FlagsStatus)> _statusListeners = [];
  bool _loaded = false;
  String? requestId;
  int _seq = 0;

  void setDefinitions(List<Json> defs) => _defs = defs;

  /// Called after every successful reload with all flag values.
  void onFeatureFlags(void Function(Map<String, dynamic>) fn) => _listeners.add(fn);

  /// Person properties used for flag evaluation only (no `$set` event, so no ingestion race).
  Future<void> setPersonPropertiesForFlags(Map<String, dynamic> props, {bool reload = true}) {
    _personProps.addAll(props);
    return reload ? this.reload() : Future.value();
  }

  Future<void> resetPersonPropertiesForFlags({bool reload = true}) {
    _personProps.clear();
    return reload ? this.reload() : Future.value();
  }

  Future<void> setGroupPropertiesForFlags(String type, Map<String, dynamic> props, {bool reload = true}) {
    _groupProps[type] = {...?_groupProps[type], ...props};
    return reload ? this.reload() : Future.value();
  }

  Future<void> resetGroupPropertiesForFlags({bool reload = true}) {
    _groupProps.clear();
    return reload ? this.reload() : Future.value();
  }

  /// `changed` after each successful reload, `stale` when a reload fails after a success, `error` when none has succeeded yet.
  void onFlagsStatus(void Function(FlagsStatus) fn) => _statusListeners.add(fn);

  void _fail() {
    final s = _loaded ? FlagsStatus.stale : FlagsStatus.error;
    for (final l in List.of(_statusListeners)) {
      l(s);
    }
  }

  void _notify() {
    _loaded = true;
    final snapshot = all;
    for (final l in _listeners) {
      l(snapshot);
    }
    for (final l in List.of(_statusListeners)) {
      l(FlagsStatus.changed);
    }
  }

  Json get _ctx => {
        'distinct_id': _core.distinctId,
        'groups': _core.groups ?? {},
        'person_properties': Map.of(_personProps),
        if (_groupProps.isNotEmpty) 'group_properties': Map.of(_groupProps),
        'device_properties': deviceProperties,
        if (appVersion != null) 'app_version': appVersion,
      };

  /// Local pass; returns true when the server must decide (or there are no definitions).
  bool _evalLocal() {
    if (_defs.isEmpty) return true;
    var server = false;
    final v = <String, dynamic>{};
    final p = <String, dynamic>{};
    evaluateAll(_defs, _ctx).forEach((k, r) {
      if (requiresServer(r)) {
        server = true;
      } else {
        v[k] = r['value'];
        if (r['payload'] != null) p[k] = r['payload'];
        _meta[k] = FlagMeta(r['reason'] as String? ?? '', (r['condition_index'] as num?)?.toInt() ?? -1, true);
      }
    });
    _local = v;
    _values = {..._values, ...v};
    _payloads = {..._payloads, ...p};
    return server;
  }

  Future<void> reload() async {
    final mine = ++_seq;
    if (!_evalLocal()) return _notify();
    if (!_core.consent.has('analytics')) return;
    final r = await _core.c.http.send('POST', '${_core.c.apiHost}/v1/flags',
        body: jsonEncode({
          'api_key': _core.c.apiKey,
          'distinct_id': _core.distinctId,
          if (_core.anonDistinctId != null) 'anon_distinct_id': _core.anonDistinctId,
          'groups': _core.groups ?? {},
          'person_properties': Map.of(_personProps),
          if (_groupProps.isNotEmpty) 'group_properties': _groupProps,
          if (options.evaluationContexts.isNotEmpty) 'evaluation_contexts': options.evaluationContexts,
        }),
        headers: {'Content-Type': 'application/json'});
    if (mine != _seq) return;
    Json? j;
    if (r.status >= 200 && r.status < 300) {
      try {
        j = jsonDecode(r.body) as Json;
      } catch (_) {/* treated as a failed load */}
    }
    if (j == null) return _fail();
    final v = <String, dynamic>{};
    final p = <String, dynamic>{};
    (j['flags'] as Map? ?? {}).forEach((k, x) {
      if (x is Map) {
        v[k as String] = x['value'] ?? x['variant'] ?? (x['enabled'] == true);
        if (x['payload'] != null) p[k] = x['payload'];
        _meta[k] = FlagMeta(x['reason'] as String? ?? '', (x['condition_index'] as num?)?.toInt() ?? -1, false);
      } else {
        v[k as String] = x;
      }
    });
    requestId = j['request_id'] as String?;
    _values = {..._local, ...v};
    _payloads = p;
    _core.storage.set(_cacheKey, jsonEncode({'values': _values, 'payloads': _payloads}));
    _notify();
  }

  /// Value, payload, variant, raw Lucida reason and request id. A key with no value is served from
  /// [FlagOptions.fallbacks] with reason `fallback` (no event); null when it has no fallback either.
  FlagDetails? getFeatureFlagDetails(String key) {
    if (!_values.containsKey(key)) {
      return options.fallbacks.containsKey(key)
          ? FlagDetails(options.fallbacks[key], null, null, 'fallback', -1, null, false)
          : null;
    }
    final v = get(key);
    final m = _meta[key];
    return FlagDetails(v, _payloads[key], v is String ? v : null, m?.reason ?? '', m?.conditionIndex ?? -1, requestId,
        m?.local ?? false);
  }

  /// false | true | variant key. Emits `$feature_flag_called` once per key/value; fallbacks emit nothing.
  Object? get(String key) {
    // a configured fallback is served silently; a missing flag without one still reports `false`
    if (!_values.containsKey(key) && options.fallbacks[key] != null) return options.fallbacks[key];
    final v = _values[key] ?? false;
    if (options.sendFeatureFlagEvent && !_called.contains('$key=$v')) {
      _called.add('$key=$v');
      _core.capture('\$feature_flag_called', {'\$feature_flag': key, '\$feature_flag_response': v});
    }
    return v;
  }

  final Set<String> _called = {};
  bool isEnabled(String key) => get(key) != false;
  Object? payload(String key) => _payloads[key];
  Map<String, dynamic> get all => Map.of(_values);
}
