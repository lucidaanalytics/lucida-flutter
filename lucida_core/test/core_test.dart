import 'dart:convert';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class FakeHttp implements HttpPort {
  final List<String> bodies = [];
  final List<String> urls = [];
  final List<bool> gzips = [];
  List<int> statuses = [200];
  String response = '{}';
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    urls.add('$method $url');
    gzips.add(gzip);
    if (body != null) bodies.add(body);
    final s = statuses.length > 1 ? statuses.removeAt(0) : statuses.first;
    return HttpResult(s, response);
  }
}

int clock = 1760000000000;

({Core core, FakeHttp http, MemoryStore store}) make(
    {ConsentMode mode = ConsentMode.optOut, MemoryStore? store, FakeHttp? http, int flushAt = 2}) {
  final h = http ?? FakeHttp();
  final st = store ?? MemoryStore();
  final core = Core(CoreConfig(
    apiKey: 'lc_pk_x',
    apiHost: 'https://ingest.test/',
    http: h,
    store: st,
    libName: 'lucida-dart',
    libVersion: '0.1.0',
    now: () => clock,
    consentMode: mode,
    flushAt: flushAt,
    flushIntervalMs: 60000,
    random: () => 0,
  ));
  return (core: core, http: h, store: st);
}

void main() {
  test('batches at flushAt, gzips, wire shape', () async {
    final t = make();
    t.core.capture('a');
    t.core.capture('b');
    await t.core.flush();
    expect(t.http.urls.single, 'POST https://ingest.test/v1/batch?compression=gzip');
    expect(t.http.gzips.single, isTrue);
    final body = jsonDecode(t.http.bodies.single) as Map;
    expect(body['api_key'], 'lc_pk_x');
    final e = (body['batch'] as List).first as Map;
    expect(e['properties']['\$lib'], 'lucida-dart');
    expect(e['properties']['\$session_id'], isNotEmpty);
    expect(t.core.queue.size, 0);
  });

  test('retries a 500 then succeeds; queue persisted until acked', () async {
    final h = FakeHttp()..statuses = [500, 200];
    final t = make(http: h);
    t.core.capture('a');
    t.core.capture('b'); // reaches flushAt: first attempt fails with 500
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(t.core.queue.size, 2);
    expect(t.store.get('lc_queue'), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 700)); // backoff timer retries and succeeds
    expect(t.core.queue.size, 0);
    expect(t.store.get('lc_queue'), isNull);
  });

  test('queue survives restart', () async {
    final h = FakeHttp()..statuses = [0];
    final t = make(http: h, flushAt: 100);
    t.core.capture('a');
    final again = make(store: t.store, flushAt: 100);
    expect(again.core.queue.size, 1);
  });

  test('drops non-retryable 400', () async {
    final dropped = <String>[];
    final h = FakeHttp()..statuses = [400];
    final core = Core(CoreConfig(
        apiKey: 'k',
        apiHost: 'h',
        http: h,
        store: MemoryStore(),
        libName: 'l',
        libVersion: '1',
        flushAt: 1,
        onDrop: (_, r) => dropped.add(r)));
    core.capture('a');
    await core.flush();
    expect(dropped, ['status_400']);
    expect(core.queue.size, 0);
  });

  test('opt-in: nothing stored or sent before consent; granted releases', () async {
    final t = make(mode: ConsentMode.optIn);
    t.core.capture('x');
    t.core.register({'a': 1});
    t.core.identify('user-1');
    expect(t.store.data, isEmpty);
    expect(t.http.bodies, isEmpty);
    t.core.optIn();
    expect(t.store.get('lc_identity'), contains('user-1'));
    expect(t.store.get('lc_consent'), contains('true'));
    t.core.capture('y');
    await t.core.flush();
    expect(t.http.bodies, isNotEmpty);
  });

  test('the stored queue is segmented: an enqueue touches one segment, a restart resumes all', () async {
    final t = make(flushAt: 1000);
    for (var i = 0; i < 120; i++) {
      t.core.capture('e$i');
    }
    expect(t.store.get('lc_queue'), '{"segs":3}');
    expect(t.store.get('lc_queue.2'), isNotNull);
    expect(t.store.get('lc_queue.3'), isNull);
    final again = make(store: t.store, flushAt: 1000);
    expect(again.core.queue.size, 120);
    t.store.set('lc_queue.1', 'torn');
    expect(make(store: t.store, flushAt: 1000).core.queue.size, 70); // only the torn segment is lost
    t.store.set(
        'lc_queue',
        jsonEncode([
          {'uuid': 'u1', 'event': 'old', 'distinct_id': 'd', 'properties': {}}
        ]));
    expect(make(store: t.store, flushAt: 1000).core.queue.size, 1); // the pre-segment layout migrates
    expect(t.store.get('lc_queue'), '{"segs":1}');
  });

  test('opt-out wipes queue and stops capture', () async {
    final t = make(flushAt: 100);
    t.core.capture('a');
    expect(t.store.get('lc_queue'), isNotNull);
    t.core.optOut();
    expect(t.store.get('lc_queue'), isNull);
    expect(t.core.capture('b'), isNull);
  });

  test('anonDistinctId is set only after identify (LC-FLG-34)', () {
    final t = make();
    expect(t.core.anonDistinctId, isNull);
    final anon = t.core.distinctId;
    t.core.identify('u1');
    expect(t.core.anonDistinctId, anon);
  });

  test('identify links anon id once; alias; groups; super props; reset', () {
    final t = make(flushAt: 100);
    final anon = t.core.distinctId;
    final seen = <WireEvent>[];
    t.core.onCaptured(seen.add);
    t.core.register({'plan': 'pro'});
    t.core.identify('u1', {'email': 'a@b.c'});
    expect(seen.last['properties']['\$anon_distinct_id'], anon);
    expect(seen.last['distinct_id'], 'u1');
    expect(seen.last['\$set'], {'email': 'a@b.c'});
    t.core.identify('u2');
    expect(seen.last['properties'].containsKey('\$anon_distinct_id'), isFalse);
    t.core.alias('al');
    expect(seen.last['properties']['alias'], 'al');
    t.core.group('company', 'acme');
    t.core.capture('z');
    expect(seen.last['\$groups'], {'company': 'acme'});
    expect(seen.last['properties']['plan'], 'pro');
    t.core.reset();
    expect(t.core.distinctId, isNot('u2'));
    t.core.capture('after');
    expect(seen.last.containsKey('\$groups'), isFalse);
  });

  test('session rotates after 30 minutes idle', () {
    final t = make(flushAt: 100);
    final a = t.core.capture('a')!['properties']['\$session_id'];
    clock += 29 * 60000;
    expect(t.core.capture('b')!['properties']['\$session_id'], a);
    clock += 31 * 60000;
    expect(t.core.capture('c')!['properties']['\$session_id'], isNot(a));
  });

  test('facade sessionId matches the captured \$session_id and rotates', () {
    final lc = Lucida(
        CoreConfig(
          apiKey: 'lc_pk_x',
          apiHost: 'https://ingest.test/',
          http: FakeHttp(),
          store: MemoryStore(),
          libName: 'lucida-dart',
          libVersion: '0.1.0',
          now: () => clock,
          flushAt: 100,
          flushIntervalMs: 60000,
          random: () => 0,
        ),
        appVersion: '1.0');
    final sid = lc.sessionId;
    expect(lc.core.capture('e')!['properties']['\$session_id'], sid);
    clock += 31 * 60000;
    expect(lc.sessionId, isNot(sid));
  });

  test('screen view', () {
    final t = make(flushAt: 100);
    final seen = <WireEvent>[];
    t.core.onCaptured(seen.add);
    t.core.screen('Cart', {'k': 1});
    expect(seen.single['event'], '\$screen');
    expect(seen.single['properties']['\$screen_name'], 'Cart');
    expect(t.core.queue.size, 1);
  });

  test('lifecycle: installed, opened, updated, backgrounded', () async {
    final t = make(flushAt: 100);
    final names = <String>[];
    t.core.onCaptured((e) => names.add(e['event'] as String));
    Lifecycle(t.core, version: '1.0').launched();
    expect(names, ['\$app_installed', '\$app_opened']);
    names.clear();
    Lifecycle(t.core, version: '1.1').launched();
    expect(names, ['\$app_updated', '\$app_opened']);
    names.clear();
    await Lifecycle(t.core, version: '1.1').backgrounded();
    expect(names, ['\$app_backgrounded']);
    expect(t.http.bodies, isNotEmpty);
  });

  test('flags: server response + cache + called event', () async {
    final h = FakeHttp()..response = '{"flags":{"f":{"enabled":true,"variant":"b"},"g":false},"request_id":"r1"}';
    final t = make(http: h, flushAt: 100);
    final f = Flags(t.core);
    await f.reload();
    expect(f.get('f'), 'b');
    expect(f.isEnabled('g'), isFalse);
    expect(Flags(t.core).get('f'), 'b'); // cold start from cache
  });

  test('flags: local definitions skip the network', () async {
    final t = make(flushAt: 100);
    final f = Flags(t.core, definitions: [
      {
        'key': 'on',
        'type': 'boolean',
        'active': true,
        'salt': 's',
        'aggregation': {'kind': 'person'},
        'conditions': [
          {'rollout_pct': 100}
        ]
      },
    ]);
    await f.reload();
    expect(f.isEnabled('on'), isTrue);
    expect(t.http.urls, isEmpty);
  });

  test('uuidv7 shape', () {
    final t = make(flushAt: 100);
    expect(t.core.capture('a')!['uuid'],
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });
}
