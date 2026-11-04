import 'dart:convert';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class _Http implements HttpPort {
  final List<Map<String, dynamic>> chunks = [];
  int status = 200;
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    if (url.contains('/v1/replay')) {
      if (status >= 200 && status < 300) chunks.add(jsonDecode(body!) as Map<String, dynamic>);
      return HttpResult(status);
    }
    return const HttpResult(200, '');
  }
}

class _Source implements WidgetTreeSource {
  String label = 'Hello';
  @override
  WireSnapshot? snapshot(String screen) => WireSnapshot(screen, 100, 200,
      WireNode(WireKind.view, 0, 0, 100, 200, children: [WireNode(WireKind.label, 10, 10, 50, 20, text: label)]));
}

class _Rev implements QueueCipher {
  @override
  String encrypt(String plain) => 'enc:${plain.split('').reversed.join()}';
  @override
  String? decrypt(String cipher) => cipher.startsWith('enc:') ? cipher.substring(4).split('').reversed.join() : null;
}

int _now = 1760000000000;

Core _core(_Http http, MemoryStore store, {QueueCipher? cipher, void Function(List<WireEvent>, String)? onDrop}) =>
    Core(CoreConfig(
      apiKey: 'lc_pk_x',
      apiHost: 'https://ingest.test/',
      http: http,
      store: store,
      libName: 'lucida-dart',
      libVersion: '0.1.0',
      now: () => _now,
      flushIntervalMs: 60000,
      random: () => 0,
      queueCipher: cipher,
      onDrop: onDrop,
    ));

ReplayRecorder _rec(Core c, _Source s, {int budget = 10 * 1024 * 1024}) =>
    ReplayRecorder(c, s, useRemoteConfig: false, spoolBudgetBytes: budget);

void main() {
  test('offline chunks spill to disk, survive a restart and upload in order', () async {
    final http = _Http()..status = 0;
    final store = MemoryStore();
    final src = _Source();
    final r1 = _rec(_core(http, store), src);
    await r1.tick();
    src.label = 'Two';
    await r1.tick();
    expect(http.chunks, isEmpty);
    expect(store.data.keys.where((k) => k.startsWith('lc_replay.')), hasLength(2));

    http.status = 200;
    final r2 = _rec(_core(http, store), src); // new process, same store
    await r2.tick();
    expect(http.chunks.take(2).map((c) => c['seq']), [0, 1]);
    expect(store.data.keys.where((k) => k.startsWith('lc_replay')), isEmpty);
  });

  test('a non-retryable rejection drops the chunk instead of looping', () async {
    final http = _Http()..status = 400;
    final store = MemoryStore();
    await _rec(_core(http, store), _Source()).tick();
    expect(store.data.keys.where((k) => k.startsWith('lc_replay')), isEmpty);
  });

  test('spilled chunks are encrypted when the queue cipher is set', () async {
    final http = _Http()..status = 0;
    final store = MemoryStore();
    await _rec(_core(http, store, cipher: _Rev()), _Source()).tick();
    final body = store.data.entries.firstWhere((e) => e.key.startsWith('lc_replay.')).value;
    expect(body, startsWith('enc:'));
    expect(body, isNot(contains('session_id')));
  });

  test('clearSpool erases everything (opt-out / reset)', () async {
    final http = _Http()..status = 0;
    final store = MemoryStore();
    final r = _rec(_core(http, store), _Source());
    await r.tick();
    r.clearSpool();
    expect(store.data.keys.where((k) => k.startsWith('lc_replay')), isEmpty);
  });

  test('over budget the oldest whole session goes and the loss is reported', () {
    final store = MemoryStore();
    final dropped = <String>[];
    final s = ReplaySpool(store, budgetBytes: 100, onDrop: (sid, n, b) => dropped.add('$sid:$n:$b'));
    final body = 'x' * 40;
    s.add('a', 0, false, body);
    s.add('a', 1, false, body);
    s.add('b', 0, false, body); // 120 > 100: all of session a goes, not just one chunk
    expect(dropped, ['a:2:80']);
    expect(s.entries.map((c) => c.sid), ['b']);
    expect(store.data.keys.where((k) => k.startsWith('lc_replay.')), hasLength(1));
  });

  test('a restarted spool reloads its index and resumes seq', () {
    final store = MemoryStore();
    ReplaySpool(store)
      ..add('a', 0, true, '{}')
      ..add('a', 1, true, '{}');
    final s = ReplaySpool(store);
    expect(s.entries, hasLength(2));
    expect(s.nextSeq('a'), 2);
    expect(s.nextSeq('zzz'), 0);
  });
}
