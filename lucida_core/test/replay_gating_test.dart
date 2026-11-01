import 'dart:convert';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class _Http implements HttpPort {
  final List<Map<String, dynamic>> chunks = [];
  final List<String> urls = [];
  String configBody = '';
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    urls.add('$method $url');
    if (url.contains('/v1/replay')) {
      chunks.add(jsonDecode(body!) as Map<String, dynamic>);
      return const HttpResult(200);
    }
    if (url.contains('/v1/config')) return HttpResult(200, configBody);
    return const HttpResult(200);
  }
}

class _Source implements WidgetTreeSource {
  String label = 'Hello';
  @override
  WireSnapshot? snapshot(String screen) => WireSnapshot(
        screen,
        100,
        200,
        WireNode(WireKind.view, 0, 0, 100, 200, children: [
          WireNode(WireKind.label, 10, 10, 50, 20, text: label),
        ]),
      );
}

int _now = 1760000000000;

({Core core, _Http http, _Source src}) env() {
  final http = _Http();
  final core = Core(CoreConfig(
    apiKey: 'lc_pk_x',
    apiHost: 'https://ingest.test/',
    http: http,
    store: MemoryStore(),
    libName: 'lucida-dart',
    libVersion: '0.1.0',
    now: () => _now,
    flushIntervalMs: 60000,
    random: () => 0,
  ));
  return (core: core, http: http, src: _Source());
}

void main() {
  test('screen lists: deny wins, empty allow means all', () {
    expect(ReplayPolicy.screenAllowed('A', [], []), isTrue);
    expect(ReplayPolicy.screenAllowed('A', ['B'], []), isFalse);
    expect(ReplayPolicy.screenAllowed('A', ['A'], ['A']), isFalse);
    expect(ReplayPolicy.screenAllowed('A', [], ['B']), isTrue);
  });

  test('remote config can only tighten', () {
    const r = RemoteReplayConfig(sampleRate: 0.5, minDurationMs: 3000);
    expect(ReplayPolicy.sampleRate(1, r), 0.5);
    expect(ReplayPolicy.sampleRate(0.1, r), 0.1);
    expect(ReplayPolicy.minDurationMs(5000, r), 5000);
    expect(ReplayPolicy.minDurationMs(0, r), 3000);
    expect(ReplayPolicy.sampleRate(1, const RemoteReplayConfig(sessionRecording: false)), 0);
    expect(ReplayPolicy.sampleRate(1, null), 1);
    expect(RemoteReplayConfig.parse('{"session_recording":false}')!.sessionRecording, isFalse);
    expect(RemoteReplayConfig.parse('nope'), isNull);
  });

  test('remote kill switch stops recording; useRemoteConfig false ignores it', () async {
    final e = env();
    e.http.configBody = '{"session_recording":false}';
    final rec = ReplayRecorder(e.core, e.src);
    await rec.tick();
    expect(e.http.chunks, isEmpty);
    expect(e.http.urls, contains('GET https://ingest.test/v1/config?api_key=lc_pk_x'));
    final e2 = env();
    e2.http.configBody = '{"session_recording":false}';
    await ReplayRecorder(e2.core, e2.src, useRemoteConfig: false).tick();
    expect(e2.http.chunks, hasLength(1));
  });

  test('min duration holds chunks, flushes them in order, and drops them on stop', () async {
    final e = env();
    final rec = ReplayRecorder(e.core, e.src, minDurationMs: 10000);
    await rec.tick();
    e.src.label = 'Changed';
    _now += 4000;
    await rec.tick();
    expect(e.http.chunks, isEmpty);
    e.src.label = 'Again';
    _now += 7000;
    await rec.tick();
    expect(e.http.chunks.map((c) => c['seq']), [0, 1, 2]);

    final e2 = env();
    final r2 = ReplayRecorder(e2.core, e2.src, minDurationMs: 10000);
    await r2.tick();
    r2.stop();
    e2.src.label = 'x';
    _now += 20000;
    await r2.tick();
    expect(e2.http.chunks, hasLength(1), reason: 'only the fresh snapshot after the stop');
    expect(e2.http.chunks.single['seq'], 0);
  });

  test('remote min duration applies', () async {
    final e = env();
    e.http.configBody = '{"session_recording":true,"replay_min_duration_ms":5000}';
    await ReplayRecorder(e.core, e.src).tick();
    expect(e.http.chunks, isEmpty);
  });

  test('linked flag gates recording', () async {
    final e = env();
    var on = false;
    final rec = ReplayRecorder(e.core, e.src, linkedFlag: 'f', flagEnabled: (k) => k == 'f' && on);
    await rec.tick();
    expect(e.http.chunks, isEmpty);
    on = true;
    await rec.tick();
    expect(e.http.chunks, hasLength(1));
    rec.start();
    expect(rec.isActive, isTrue);
    on = false;
    expect(rec.isActive, isFalse);
    rec.stop();
  });

  test('denied screen pauses, re-entering sends a fresh snapshot, not-allowed screens are skipped', () async {
    final e = env();
    final rec = ReplayRecorder(e.core, e.src, screenAllowList: ['Home', 'Checkout'], screenDenyList: ['Checkout']);
    rec.setScreen('Home');
    await rec.tick();
    rec.setScreen('Checkout');
    await rec.tick();
    expect(e.http.chunks, hasLength(1));
    rec.setScreen('Home');
    await rec.tick();
    expect(e.http.chunks, hasLength(2));
    rec.setScreen('Other');
    await rec.tick();
    expect(e.http.chunks, hasLength(2));
  });

  test('pause and resume', () async {
    final e = env();
    final rec = ReplayRecorder(e.core, e.src)..start();
    expect(rec.isActive, isTrue);
    rec.pause();
    expect(rec.isActive, isFalse);
    await rec.tick();
    expect(e.http.chunks, isEmpty);
    rec.resume();
    expect(rec.isActive, isTrue);
    rec.stop();
  });

  test('captureTouches records a tap against the last snapshot; off drops it', () async {
    for (final on in [true, false]) {
      final e = env();
      final rec = ReplayRecorder(e.core, e.src, captureTouches: on);
      rec.tap(1, 1); // before any snapshot: dropped
      await rec.tick();
      rec.tap(15, 15);
      e.src.label = 'Changed';
      await rec.tick();
      final types = (e.http.chunks.last['events'] as List).map((x) => (x as Map)['type']).toList();
      expect(types, on ? [3, 4, 2] : [4, 2]);
      if (on) {
        final tap = (e.http.chunks.last['events'] as List).first as Map;
        expect((tap['data'] as Map)['id'], 4); // root 3, label 4 (its text node is 5)
      }
    }
  });
}
