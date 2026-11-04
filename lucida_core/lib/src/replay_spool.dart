import 'dart:convert';

import 'ports.dart';

/// One spilled replay chunk: the wire body minus the api key.
class SpooledChunk {
  const SpooledChunk(this.id, this.sid, this.seq, this.held, this.bytes);
  final int id;
  final String sid;
  final int seq;

  /// Waiting for the minimum session duration (dropped if the session ends first); false = waiting for upload.
  final bool held;
  final int bytes;
}

/// Durable, ordered spill for replay chunks that cannot be sent yet (min duration, offline, upload backoff).
/// Layout: `lc_replay` is the index (JSON list of entries), `lc_replay.<id>` holds one chunk body. Pass a store wrapped in
/// `EncryptedStore(..., {'lc_replay'}, ['lc_replay.'])` to encrypt at rest. Over [budgetBytes] the oldest whole session
/// is dropped (never single chunks, so a kept session has no hole) and [onDrop] reports it.
class ReplaySpool {
  ReplaySpool(this._store, {this.budgetBytes = 10 * 1024 * 1024, this.onDrop}) {
    _load();
  }

  static const _key = 'lc_replay';
  final KeyValueStore _store;
  final int budgetBytes;
  final void Function(String sid, int chunks, int bytes)? onDrop;
  final List<SpooledChunk> _items = [];
  int _nextId = 0;

  List<SpooledChunk> get entries => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get totalBytes => _items.fold(0, (a, e) => a + e.bytes);

  void _load() {
    try {
      final raw = _store.get(_key);
      if (raw == null) return;
      for (final e in jsonDecode(raw) as List) {
        final m = e as Map;
        final c = SpooledChunk(m['id'] as int, m['sid'] as String, m['seq'] as int, m['held'] as bool, m['n'] as int);
        if (_store.get('$_key.${c.id}') != null) _items.add(c);
        if (c.id >= _nextId) _nextId = c.id + 1;
      }
    } catch (_) {
      _items.clear(); // a corrupt index starts empty
    }
  }

  void _save() => _items.isEmpty
      ? _store.remove(_key)
      : _store.set(_key,
          jsonEncode([for (final c in _items) {'id': c.id, 'sid': c.sid, 'seq': c.seq, 'held': c.held, 'n': c.bytes}]));

  void add(String sid, int seq, bool held, String body) {
    final c = SpooledChunk(_nextId++, sid, seq, held, utf8.encode(body).length);
    _store.set('$_key.${c.id}', body);
    _items.add(c);
    while (totalBytes > budgetBytes && _items.isNotEmpty) {
      _dropSession(_items.first.sid);
    }
    _save();
  }

  void _dropSession(String sid) {
    final gone = _items.where((c) => c.sid == sid).toList();
    for (final c in gone) {
      _store.remove('$_key.${c.id}');
    }
    _items.removeWhere((c) => c.sid == sid);
    onDrop?.call(sid, gone.length, gone.fold(0, (a, c) => a + c.bytes));
  }

  String? read(SpooledChunk c) => _store.get('$_key.${c.id}');

  void remove(SpooledChunk c) {
    _store.remove('$_key.${c.id}');
    _items.removeWhere((e) => e.id == c.id);
    _save();
  }

  /// Held chunks of every session except [keepSid] (that session reached its minimum, or ended short).
  List<SpooledChunk> removeHeld({String? exceptSid}) {
    final gone = _items.where((c) => c.held && c.sid != exceptSid).toList();
    for (final c in gone) {
      _store.remove('$_key.${c.id}');
      _items.remove(c);
    }
    _save();
    return gone;
  }

  /// The session reached its minimum duration: its held chunks become plain pending uploads.
  void release(String sid) {
    for (var i = 0; i < _items.length; i++) {
      final c = _items[i];
      if (c.held && c.sid == sid) _items[i] = SpooledChunk(c.id, c.sid, c.seq, false, c.bytes);
    }
    _save();
  }

  int nextSeq(String sid) => _items.where((c) => c.sid == sid).fold(-1, (a, c) => c.seq > a ? c.seq : a) + 1;

  void clear() {
    for (final c in _items) {
      _store.remove('$_key.${c.id}');
    }
    _items.clear();
    _save();
  }
}
