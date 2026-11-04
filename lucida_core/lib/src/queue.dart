import 'dart:async';
import 'dart:convert';

import 'ports.dart';
import 'retry.dart';

typedef WireEvent = Map<String, dynamic>;

/// Persistent batching queue: flush at N events or T ms, retry with backoff, drop-oldest when full.
/// Items are mirrored to [store] so a killed app resumes where it left off.
/// Storage layout: `lc_queue` is the index ({"segs": n}), `lc_queue.<i>` holds segment i (up to [segmentSize] events).
/// An enqueue rewrites only the last segment; a settled batch or a drop of the oldest re-segments from the head.
class EventQueue {
  EventQueue({
    required this.http,
    required this.url,
    required this.apiKey,
    required this.store,
    required this.now,
    this.flushAt = 20,
    this.flushIntervalMs = 5000,
    this.maxQueueSize = 1000,
    this.maxRetries = 5,
    this.maxBatchSize = 100,
    this.retryBaseMs = 1000,
    this.networkAllowed,
    this.random,
    this.onDrop,
  }) {
    _load();
  }

  void _load() {
    final raw = store.get(_key);
    if (raw == null) return;
    List<WireEvent> events(String json) =>
        (jsonDecode(json) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        // the pre-segment layout: one JSON list under lc_queue
        _items.addAll(events(raw));
        _persistAll();
        return;
      }
      final n = (d as Map)['segs'] as int;
      for (var i = 0; i < n; i++) {
        final seg = store.get('$_key.$i');
        if (seg == null) continue;
        try {
          _items.addAll(events(seg));
        } catch (_) {/* a torn segment loses only itself */}
      }
      _segs = n;
    } catch (_) {/* corrupt index: start empty */}
  }

  static const _key = 'lc_queue';
  static const segmentSize = 50;
  final HttpPort http;
  final String url;
  final String apiKey;
  final KeyValueStore store;
  final Now now;
  final int flushAt;
  final int flushIntervalMs;
  final int maxQueueSize;
  final int maxRetries;
  final int maxBatchSize;
  final int retryBaseMs;

  /// Wi-Fi-only data mode: return false on cellular; events then wait in the queue.
  final bool Function()? networkAllowed;
  final double Function()? random;
  final void Function(List<WireEvent> events, String reason)? onDrop;
  final List<WireEvent> _items = [];
  Timer? _timer;
  Future<void>? _inflight;
  int _attempt = 0;
  bool _closed = false;

  int get size => _items.length;

  int _segs = 0; // segments currently in the store

  int get _segCount => (_items.length + segmentSize - 1) ~/ segmentSize;

  /// Rewrites every segment from the head (after items left the front), and drops stale ones.
  void _persistAll() {
    final n = _segCount;
    for (var i = 0; i < n; i++) {
      final end = (i + 1) * segmentSize;
      store.set('$_key.$i', jsonEncode(_items.sublist(i * segmentSize, end < _items.length ? end : _items.length)));
    }
    for (var i = n; i < _segs; i++) {
      store.remove('$_key.$i');
    }
    _segs = n;
    n == 0 ? store.remove(_key) : store.set(_key, jsonEncode({'segs': n}));
  }

  /// After an append only the last segment changed.
  void _persistTail() {
    final n = _segCount;
    store.set('$_key.${n - 1}', jsonEncode(_items.sublist((n - 1) * segmentSize)));
    if (n != _segs) {
      _segs = n;
      store.set(_key, jsonEncode({'segs': n}));
    }
  }

  void enqueue(WireEvent e) {
    if (_closed) return;
    _items.add(e);
    if (_items.length > maxQueueSize) {
      onDrop?.call(_items.sublist(0, _items.length - maxQueueSize), 'queue_full');
      _items.removeRange(0, _items.length - maxQueueSize);
      _persistAll();
    } else {
      _persistTail();
    }
    if (_items.length >= flushAt) {
      flush();
    } else {
      _arm(flushIntervalMs);
    }
  }

  void _arm(int ms) => _timer ??= Timer(Duration(milliseconds: ms), () {
        _timer = null;
        flush();
      });

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> flush() {
    _disarm();
    final inflight = _inflight;
    if (inflight != null) return inflight.then((_) => _items.isEmpty ? null : flush());
    if (_items.isEmpty) return Future.value();
    if (!(networkAllowed?.call() ?? true)) {
      _arm(flushIntervalMs);
      return Future.value();
    }
    final batch = _items.take(maxBatchSize < 1 ? 1 : maxBatchSize).toList();
    final body = jsonEncode({
      'api_key': apiKey,
      'batch': batch,
      'sent_at': DateTime.fromMillisecondsSinceEpoch(now(), isUtc: true).toIso8601String(),
    });
    // Events stay persisted until the server acknowledges them (at-least-once; the uuid dedupes).
    final p = http
        .send('POST', '$url?compression=gzip', body: body, headers: {'Content-Type': 'application/json'}, gzip: true)
        .then((r) => r.status, onError: (_) => 0)
        .then((status) => _settle(batch, status))
        .whenComplete(() => _inflight = null);
    _inflight = p;
    return p;
  }

  void _settle(List<WireEvent> batch, int status) {
    if (status >= 200 && status < 300) {
      _items.removeRange(0, batch.length.clamp(0, _items.length));
      _persistAll();
      _attempt = 0;
      if (_items.length >= flushAt) {
        flush();
      } else if (_items.isNotEmpty) {
        _arm(flushIntervalMs);
      }
      return;
    }
    if (!isRetryable(status) || _attempt >= maxRetries) {
      _items.removeRange(0, batch.length.clamp(0, _items.length));
      _persistAll();
      onDrop?.call(batch, 'status_$status');
      _attempt = 0;
      return;
    }
    _arm(backoffDelay(_attempt++, baseMs: retryBaseMs, random: random));
  }

  /// Discard everything (consent revoked).
  void clear() {
    _items.clear();
    _persistAll();
    _disarm();
  }

  Future<void> shutdown() async {
    await flush();
    _closed = true;
    _disarm();
  }
}
