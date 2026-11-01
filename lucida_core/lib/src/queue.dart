import 'dart:async';
import 'dart:convert';

import 'ports.dart';
import 'retry.dart';

typedef WireEvent = Map<String, dynamic>;

/// Persistent batching queue: flush at N events or T ms, retry with backoff, drop-oldest when full.
/// Items are mirrored to [store] so a killed app resumes where it left off.
/// shortcut: rewrites the whole JSON list on every enqueue (O(n), n <= maxQueueSize); switch to an append log if profiling says so.
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
    final raw = store.get(_key);
    if (raw != null) {
      try {
        _items.addAll((jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)));
      } catch (_) {/* corrupt queue file: start empty */}
    }
  }

  static const _key = 'lc_queue';
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

  void _persist() => _items.isEmpty ? store.remove(_key) : store.set(_key, jsonEncode(_items));

  void enqueue(WireEvent e) {
    if (_closed) return;
    _items.add(e);
    if (_items.length > maxQueueSize) {
      onDrop?.call(_items.sublist(0, _items.length - maxQueueSize), 'queue_full');
      _items.removeRange(0, _items.length - maxQueueSize);
    }
    _persist();
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
      _persist();
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
      _persist();
      onDrop?.call(batch, 'status_$status');
      _attempt = 0;
      return;
    }
    _arm(backoffDelay(_attempt++, baseMs: retryBaseMs, random: random));
  }

  /// Discard everything (consent revoked).
  void clear() {
    _items.clear();
    store.remove(_key);
    _disarm();
  }

  Future<void> shutdown() async {
    await flush();
    _closed = true;
    _disarm();
  }
}
