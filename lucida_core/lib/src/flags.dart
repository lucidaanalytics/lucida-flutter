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

  void _notify() {
    final snapshot = all;
    for (final l in _listeners) {
      l(snapshot);
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
    if (mine != _seq || r.status < 200 || r.status >= 300) return;
    final j = jsonDecode(r.body) as Json;
    final v = <String, dynamic>{};
    final p = <String, dynamic>{};
    (j['flags'] as Map? ?? {}).forEach((k, x) {
      if (x is Map) {
        v[k as String] = x['value'] ?? x['variant'] ?? (x['enabled'] == true);
        if (x['payload'] != null) p[k] = x['payload'];
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

  /// false | true | variant key. Emits `$feature_flag_called` once per key/value.
  Object? get(String key) {
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
