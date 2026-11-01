import 'dart:convert';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class _Http implements HttpPort {
  final List<Map<String, dynamic>> chunks = [];
  final List<String> urls = [];
  int status = 200;
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    if (url.contains('/v1/replay')) {
      urls.add(url);
      chunks.add(jsonDecode(body!) as Map<String, dynamic>);
      return HttpResult(status);
    }
    return const HttpResult(200);
  }
}

class _Source implements WidgetTreeSource {
  String label = 'Hello Ann';
  bool fail = false;
  @override
  WireSnapshot? snapshot(String screen) {
    if (fail) throw StateError('tree walk failed');
    return WireSnapshot(
      screen,
      390,
      844,
      WireNode(WireKind.view, 0, 0, 390, 844, children: [
        WireNode(WireKind.label, 10, 20, 100, 20, text: label),
        const WireNode(WireKind.input, 10, 60, 200, 30, text: 'secret@x.com'),
        const WireNode(WireKind.label, 10, 100, 100, 20, text: '4111 1111', sensitive: true),
      ]),
    );
  }
}

int _clock = 1760000000000;

({Core core, _Http http, _Source src, ReplayRecorder rec}) make({ConsentMode mode = ConsentMode.optOut}) {
  final http = _Http();
  final core = Core(CoreConfig(
    apiKey: 'lc_pk_x',
    apiHost: 'https://ingest.test/',
    http: http,
    store: MemoryStore(),
    libName: 'lucida-dart',
    libVersion: '0.1.0',
    now: () => _clock,
    consentMode: mode,
    flushIntervalMs: 60000,
    random: () => 0,
  ));
  final src = _Source();
  return (core: core, http: http, src: src, rec: ReplayRecorder(core, src));
}

void main() {
  test('sends meta, navigation and a masked full snapshot; inputs and sensitive widgets never carry text', () async {
    final t = make();
    t.rec.setScreen('Cart');
    await t.rec.tick();
    final c = t.http.chunks.single;
    expect(c['api_key'], 'lc_pk_x');
    expect(c['seq'], 0);
    expect(c['session_id'], isNotEmpty);
    expect(c['window_id'], isNotEmpty);
    final events = (c['events'] as List).cast<Map<String, dynamic>>();
    expect(events.map((e) => e['type']), [4, 5, 2]);
    expect((events[0]['data'] as Map)['href'], 'app://Cart');
    expect(t.http.urls.single, 'https://ingest.test/v1/replay?compression=gzip');
    final json = jsonEncode(events);
    expect(json, isNot(contains('Hello Ann'))); // starred
    expect(json, contains('*****')); // layout survives
    expect(json, isNot(contains('secret')));
    expect(json, isNot(contains('4111')));
  });

  test('masking can be relaxed for plain text but never for inputs', () {
    final s = _Source().snapshot('S')!;
    final json = jsonEncode(fullSnapshotEvent(s, mask: false, ms: 0));
    expect(json, contains('Hello Ann'));
    expect(json, isNot(contains('secret')));
    expect(json, isNot(contains('4111')));
  });

  test('skips an unchanged tree, advances seq on change, and omits the navigation marker for the same screen',
      () async {
    final t = make();
    await t.rec.tick();
    await t.rec.tick();
    expect(t.http.chunks, hasLength(1));
    t.src.label = 'Changed';
    await t.rec.tick();
    expect(t.http.chunks, hasLength(2));
    expect(t.http.chunks[1]['seq'], 1);
    expect((t.http.chunks[1]['events'] as List).map((e) => (e as Map)['type']), [4, 2]);
  });

  test('needs analytics and replay consent; nothing is read before', () async {
    final t = make(mode: ConsentMode.optIn);
    await t.rec.tick();
    expect(t.http.chunks, isEmpty);
    t.core.consent.set({'analytics': true});
    await t.rec.tick();
    expect(t.http.chunks, isEmpty);
    t.core.consent.set({'replay': true});
    await t.rec.tick();
    expect(t.http.chunks, hasLength(1));
  });

  test('a rejected chunk is retried as a fresh snapshot with the same seq; a failing tree walk is swallowed', () async {
    final t = make();
    t.http.status = 503;
    await t.rec.tick();
    await t.rec.tick();
    expect(t.http.chunks.map((c) => c['seq']), [0, 0]);
    t.src.fail = true;
    await t.rec.tick();
    expect(t.http.chunks, hasLength(2));
  });

  test('start/stop/isActive and per-session sampling', () async {
    final t = make();
    expect(t.rec.isActive, isFalse);
    t.rec.start();
    expect(t.rec.isActive, isTrue);
    t.rec.stop();
    expect(t.rec.isActive, isFalse);
    final off = ReplayRecorder(t.core, t.src, sampleRate: 0)..start();
    expect(off.isActive, isFalse);
    await off.tick();
    expect(t.http.chunks, isEmpty);
    off.stop();
    final on = ReplayRecorder(t.core, t.src, sampleRate: 1)..start();
    expect(on.isActive, isTrue);
    on.stop();
  });
}
