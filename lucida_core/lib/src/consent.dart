import 'dart:convert';

import 'ports.dart';

enum ConsentMode { optIn, optOut }

const _key = 'lc_consent';
const _cats = ['analytics', 'replay', 'marketing'];

/// opt_in: every category starts denied. opt_out: granted unless a stored decision says otherwise.
/// Only set() writes to the real store.
class Consent {
  Consent(this._store, {this.mode = ConsentMode.optOut, this.queueBeforeConsent = false}) {
    final open = mode == ConsentMode.optOut;
    state = {for (final c in _cats) c: open};
    final raw = _store.get(_key);
    if (raw != null) {
      try {
        final s = jsonDecode(raw) as Map<String, dynamic>;
        for (final c in _cats) {
          if (s[c] is bool) state[c] = s[c] as bool;
        }
      } catch (_) {/* corrupt stored consent: keep defaults */}
    }
  }

  final KeyValueStore _store;
  final ConsentMode mode;
  final bool queueBeforeConsent;
  late final Map<String, bool> state;

  bool has(String category) => state[category] ?? false;
  bool get pending => mode == ConsentMode.optIn && !has('analytics');
  Map<String, bool> get all => Map.of(state);

  void set(Map<String, bool> update) {
    for (final c in _cats) {
      if (update[c] != null) state[c] = update[c]!;
    }
    _store.set(_key, jsonEncode(state));
  }
}

/// Keeps writes in memory until `allowed()`; guarantees no storage before consent.
class GatedStore implements KeyValueStore {
  GatedStore(this._inner, this._allowed);
  final KeyValueStore _inner;
  final bool Function() _allowed;
  final Map<String, String?> _mem = {};

  @override
  String? get(String key) => _mem.containsKey(key) ? _mem[key] : _inner.get(key);
  @override
  void set(String key, String value) => _allowed() ? _inner.set(key, value) : _mem[key] = value;
  @override
  void remove(String key) => _allowed() ? _inner.remove(key) : _mem[key] = null;

  void flushBuffered() {
    _mem.forEach((k, v) => v == null ? _inner.remove(k) : _inner.set(k, v));
    _mem.clear();
  }

  void discardBuffered() => _mem.clear();
}
