import 'dart:convert';

import 'flag_options.dart';
import 'ports.dart';
import 'uuid.dart';

Map<String, dynamic>? _load(KeyValueStore s, String key) {
  final raw = s.get(key);
  if (raw == null) return null;
  try {
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return null;
  }
}

/// Anonymous UUIDv7 until identify(); persisted through the (gated) store.
class Identity {
  Identity(this._s, this._now, {String Function()? newId, Bootstrap? bootstrap, this.reuseAnonymousId = false}) {
    _newId = newId ?? () => uuidv7(_now());
    final p = _load(_s, 'lc_identity');
    if (p != null && p['distinct_id'] is String) {
      _id = p['distinct_id'] as String;
      identified = p['identified'] == true;
      _anon = p['anon_id'] is String ? p['anon_id'] as String : _id;
      _anonLinked = p['anon_linked'] is bool ? p['anon_linked'] as bool : (identified && _anon != _id);
    } else if (bootstrap?.distinctId != null) {
      _id = bootstrap!.distinctId!;
      identified = bootstrap.isIdentified;
      _anon = identified ? _newId() : _id;
      _save();
    } else {
      _id = _newId();
      _anon = _id;
      _save();
    }
  }

  final KeyValueStore _s;
  final Now _now;
  final bool reuseAnonymousId;
  late final String Function() _newId;
  late String _id;
  late String _anon;
  // True once an $identify this device sent linked the anonymous id; a bootstrap-identified user never links.
  bool _anonLinked = false;
  bool identified = false;

  String get distinctId => _id;

  /// The device's anonymous id; survives reset() only when `reuseAnonymousId` is set.
  String get anonymousId => _anon;

  /// Pre-identify id, sent as `anon_distinct_id` to /v1/flags so continuity flags keep their bucket (LC-FLG-34).
  String? get priorAnonId => identified && _anonLinked && _anon.isNotEmpty && _anon != _id ? _anon : null;

  void _save() => _s.set('lc_identity',
      jsonEncode({'distinct_id': _id, 'anon_id': _anon, 'identified': identified, 'anon_linked': _anonLinked}));

  /// Returns the `$identify` props to send, or null when nothing changed. The previous id is linked as
  /// `$anon_distinct_id` only while anonymous (the gateway refuses to merge two identified persons).
  Map<String, dynamic>? identify(String newId) {
    if (newId.isEmpty || newId == _id) {
      if (newId.isNotEmpty && !identified) {
        identified = true;
        _save();
      }
      return null;
    }
    final prev = _id;
    final wasAnon = !identified;
    _id = newId;
    identified = true;
    if (wasAnon) _anonLinked = true;
    _save();
    return wasAnon ? {'\$anon_distinct_id': prev} : {};
  }

  void reset() {
    if (!reuseAnonymousId) _anon = _newId();
    _id = _anon;
    identified = false;
    _anonLinked = false;
    _save();
  }
}

/// UUIDv7 session rotated after 30 min idle or 24 h total.
class SessionManager {
  SessionManager(this._s, this._now, {this.idleMs = 30 * 60000, this.maxMs = 24 * 3600000});
  final KeyValueStore _s;
  final Now _now;
  final int idleMs;
  final int maxMs;
  final String windowId = uuidv7(DateTime.now().millisecondsSinceEpoch);

  String touch() {
    final t = _now();
    var s = _load(_s, 'lc_session');
    final fresh = s == null || t - (s['last'] as int) > idleMs || t - (s['start'] as int) > maxMs;
    if (fresh) s = {'id': uuidv7(t), 'start': t};
    s['last'] = t;
    _s.set('lc_session', jsonEncode(s));
    return s['id'] as String;
  }

  void reset() => _s.remove('lc_session');
}

/// Super properties merged into every event; persisted.
class SuperProps {
  SuperProps(this._s) : _p = _load(_s, 'lc_props') ?? {};
  final KeyValueStore _s;
  Map<String, dynamic> _p;

  void _save() => _s.set('lc_props', jsonEncode(_p));
  void register(Map<String, dynamic> p) {
    _p.addAll(p);
    _save();
  }

  void registerOnce(Map<String, dynamic> p) {
    p.forEach((k, v) => _p.putIfAbsent(k, () => v));
    _save();
  }

  void unregister(String key) {
    _p.remove(key);
    _save();
  }

  Map<String, dynamic> all() => Map.of(_p);

  void clear() {
    _p = {};
    _s.remove('lc_props');
  }
}

/// Group memberships (type -> key) attached to every event as `$groups`.
class Groups {
  Groups(this._s) : _g = (_load(_s, 'lc_groups') ?? {}).map((k, v) => MapEntry(k, '$v'));
  final KeyValueStore _s;
  Map<String, String> _g;

  void set(String type, String key) {
    _g[type] = key;
    _s.set('lc_groups', jsonEncode(_g));
  }

  Map<String, String>? all() => _g.isEmpty ? null : Map.of(_g);

  void clear() {
    _g = {};
    _s.remove('lc_groups');
  }
}
