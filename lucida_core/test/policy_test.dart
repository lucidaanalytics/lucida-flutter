import 'dart:convert';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

import 'core_test.dart' show FakeHttp;

int _clock = 1760000000000;

Map<String, dynamic> _props(Map<String, dynamic>? e) => e!['properties'] as Map<String, dynamic>;

Core _core({
  List<BeforeSend> beforeSend = const [],
  PersonProfiles profiles = PersonProfiles.always,
  MemoryStore? store,
  FakeHttp? http,
  Bootstrap? bootstrap,
  bool disableGeoip = false,
  bool disabled = false,
  bool reuse = false,
  String Function()? anon,
  QueueCipher? cipher,
  List<String> tracing = const [],
  bool Function()? networkAllowed,
  int maxBatchSize = 100,
  int sessionIdleMs = 30 * 60000,
  void Function(String)? log,
  bool debug = false,
}) =>
    Core(CoreConfig(
      apiKey: 'k',
      apiHost: 'https://ingest.test',
      http: http ?? FakeHttp(),
      store: store ?? MemoryStore(),
      libName: 'lucida-dart',
      libVersion: '0',
      now: () => _clock++,
      flushAt: 100,
      flushIntervalMs: 60000,
      random: () => 0,
      beforeSend: beforeSend,
      personProfiles: profiles,
      bootstrap: bootstrap,
      disableGeoip: disableGeoip,
      disabled: disabled,
      reuseAnonymousId: reuse,
      anonymousIdProvider: anon,
      queueCipher: cipher,
      tracingHeaders: tracing,
      networkAllowed: networkAllowed,
      maxBatchSize: maxBatchSize,
      sessionIdleMs: sessionIdleMs,
      log: log,
      debug: debug,
    ));

class _Rev implements QueueCipher {
  @override
  String encrypt(String plain) => 'enc:${plain.split('').reversed.join()}';
  @override
  String? decrypt(String cipher) => cipher.startsWith('enc:') ? cipher.substring(4).split('').reversed.join() : null;
}

void main() {
  group('beforeSend', () {
    test('chain amends, drops, and keeps the event when a hook throws', () {
      final logs = <String>[];
      final c = _core(debug: true, log: logs.add, beforeSend: [
        (e) => {
              ...e,
              'properties': {..._props(e), 'a': 1}
            },
        (e) => throw StateError('boom'),
        (e) => e['event'] == 'drop' ? null : e,
        (e) => {
              ...e,
              'properties': {..._props(e), 'b': _props(e)['a']}
            },
      ]);
      final e = c.capture('keep');
      expect(_props(e)['a'], 1);
      expect(_props(e)['b'], 1);
      expect(logs.single, contains('boom'));
      expect(c.capture('drop'), isNull);
      expect(c.queue.size, 1);
    });

    test('sampleHook stamps survivors', () {
      final keep = sampleHook(0.5, random: () => 0.1)({
        'event': 'x',
        'properties': {'p': 1}
      });
      expect(_props(keep)['\$sample_rate'], 0.5);
      expect(_props(keep)['p'], 1);
      expect(sampleHook(0.5, random: () => 0.9)({'event': 'x'}), isNull);
      expect(sampleHook(0, random: () => 0)({'event': 'x'}), isNull);
      final all = {'event': 'x'};
      expect(sampleHook(1, random: () => 0.99)(all), same(all));
    });
  });

  group('personProfiles', () {
    test('always is unchanged', () {
      expect(_props(_core().capture('a')), isNot(contains('\$process_person_profile')));
    });

    test('identifiedOnly flips on identify, persists, and reset clears it', () {
      final store = MemoryStore();
      final c = _core(profiles: PersonProfiles.identifiedOnly, store: store);
      expect(_props(c.capture('a'))['\$process_person_profile'], false);
      c.identify('u1');
      expect(_props(c.capture('b')), isNot(contains('\$process_person_profile')));
      final again = _core(profiles: PersonProfiles.identifiedOnly, store: store);
      expect(_props(again.capture('c')), isNot(contains('\$process_person_profile')));
      again.reset();
      expect(_props(again.capture('d'))['\$process_person_profile'], false);
    });

    test('identifiedOnly flips on a person property set', () {
      final c = _core(profiles: PersonProfiles.identifiedOnly);
      c.capture('a', const {}, {'x': 1});
      expect(_props(c.capture('b')), isNot(contains('\$process_person_profile')));
    });

    test('never blocks identity and person writes', () {
      final c = _core(profiles: PersonProfiles.never);
      final id = c.distinctId;
      c.identify('u1', {'a': 1});
      expect(c.distinctId, id);
      expect(c.alias('z'), isNull);
      expect(c.setPersonProperties({'a': 1}), isNull);
      final e = c.capture('a', const {}, {'a': 1})!;
      expect(e, isNot(contains('\$set')));
      expect(_props(e)['\$process_person_profile'], false);
      expect(c.queue.size, 1);
    });
  });

  group('core options', () {
    test('bootstrap identity, reuseAnonymousId, custom anonymous id', () {
      final c = _core(bootstrap: const Bootstrap(distinctId: 'boot-1', isIdentified: true));
      expect(c.distinctId, 'boot-1');
      expect(c.identity.identified, isTrue);
      expect(c.anonDistinctId, isNull); // a bootstrap-identified user never linked its generated anon id
      c.reset();
      expect(c.distinctId, c.anonymousId);
      final r = _core(reuse: true, anon: () => 'anon-fixed');
      expect(r.anonymousId, 'anon-fixed');
      r.identify('u');
      r.reset();
      expect(r.distinctId, 'anon-fixed');
    });

    test('disabled, geoip, session expiry, isOptedOut, runtime debug', () {
      expect(_core(disabled: true).capture('a'), isNull);
      final c = _core(disableGeoip: true, sessionIdleMs: 10);
      expect(_props(c.capture('a'))['\$geoip_disable'], true);
      final s1 = _props(c.capture('b'))['\$session_id'];
      _clock += 50;
      expect(_props(c.capture('c'))['\$session_id'], isNot(s1));
      expect(c.isOptedOut, isFalse);
      c.optOut();
      expect(c.isOptedOut, isTrue);
      final logs = <String>[];
      final d = _core(log: logs.add);
      d.debugLog('hidden');
      d.debug = true;
      d.debugLog('shown');
      expect(logs, ['shown']);
    });

    test('setPersonProperties and deep link', () {
      final c = _core();
      final e = c.setPersonProperties({'a': 1}, {'b': 2})!;
      expect(e['event'], '\$set');
      expect(e['\$set'], {'a': 1});
      expect(e['\$set_once'], {'b': 2});
      final d = c.deepLink('myapp://item/3?ref=a%20b&x=1#frag', 'ref://x')!;
      expect(d['event'], '\$deep_link_opened');
      expect(_props(d)['query'], {'ref': 'a b', 'x': '1'});
      expect(_props(d)['referrer'], 'ref://x');
    });

    test('queue: batch size and wifi-only gate', () async {
      final http = FakeHttp();
      var wifi = false;
      final c = _core(http: http, maxBatchSize: 2, networkAllowed: () => wifi);
      for (var i = 0; i < 5; i++) {
        c.capture('e$i');
      }
      await c.queue.flush();
      expect(http.bodies, isEmpty);
      expect(c.queue.size, 5);
      wifi = true;
      await c.queue.flush();
      await c.queue.flush();
      await c.queue.flush();
      expect(http.bodies, hasLength(3)); // 2 + 2 + 1
      expect(c.queue.size, 0);
    });

    test('encrypted queue at rest', () {
      final store = MemoryStore();
      final c = _core(cipher: _Rev(), store: store);
      c.capture('secret-event');
      final raw = store.get('lc_queue')!;
      expect(raw, startsWith('enc:'));
      expect(raw, isNot(contains('secret-event')));
      expect(_core(cipher: _Rev(), store: store).queue.size, 1);
      store.set('lc_queue', 'garbage');
      expect(_core(cipher: _Rev(), store: store).queue.size, 0);
    });

    test('tracing headers: host matching, never the Lucida host, consent', () {
      final c = _core(tracing: ['api.example.com', '.corp.io', 'ingest.test']);
      final h = c.tracing.headersFor('https://api.example.com/v1/x');
      expect(h['X-Lucida-Distinct-Id'], c.distinctId);
      expect(h['X-Lucida-Session-Id'], isNotEmpty);
      expect(h['baggage'], 'lucida.session_id=${h['X-Lucida-Session-Id']}');
      expect(c.tracing.headersFor('https://api.example.com/v1/x', baggage: 'a=1, lucida.session_id=old,b=2')['baggage'],
          'a=1,b=2,lucida.session_id=${h['X-Lucida-Session-Id']}');
      expect(c.tracing.headersFor('https://a.corp.io/x'), isNotEmpty);
      expect(c.tracing.headersFor('https://corp.io/x'), isEmpty);
      expect(c.tracing.headersFor('https://other.com/x'), isEmpty);
      expect(c.tracing.headersFor('https://ingest.test/v1/batch'), isEmpty);
      c.optOut();
      expect(c.tracing.headersFor('https://api.example.com/v1/x'), isEmpty);
    });
  });

  group('flags options', () {
    Future<(Core, Flags, FakeHttp)> setup({FlagOptions opts = const FlagOptions(), Bootstrap? boot}) async {
      final http = FakeHttp()..response = '{"flags":{"f":true}}';
      final c = _core(http: http, bootstrap: boot);
      return (c, Flags(c, options: opts), http);
    }

    test('exposure toggle and bootstrap values', () async {
      final (c, f, _) = await setup(
          opts: const FlagOptions(sendFeatureFlagEvent: false),
          boot: const Bootstrap(flags: {
            'b': 'v1'
          }, payloads: {
            'b': {'k': 1}
          }));
      final names = <String>[];
      c.onCaptured((e) => names.add(e['event'] as String));
      expect(f.get('b'), 'v1');
      expect(f.payload('b'), {'k': 1});
      expect(names, isEmpty);
      final (c2, f2, _) = await setup();
      final n2 = <String>[];
      c2.onCaptured((e) => n2.add(e['event'] as String));
      f2.get('x');
      expect(n2, ['\$feature_flag_called']);
    });

    test('evaluation properties, contexts and onFeatureFlags', () async {
      final (_, f, http) = await setup(opts: const FlagOptions(evaluationContexts: ['prod']));
      Map<String, dynamic>? seen;
      f.onFeatureFlags((v) => seen = v);
      await f.setPersonPropertiesForFlags({'plan': 'pro'}, reload: false);
      expect(http.bodies, isEmpty);
      await f.setGroupPropertiesForFlags('company', {'tier': 2});
      final body = jsonDecode(http.bodies.last) as Map;
      expect(body['person_properties'], {'plan': 'pro'});
      expect(body['group_properties'], {
        'company': {'tier': 2}
      });
      expect(body['evaluation_contexts'], ['prod']);
      expect(seen!['f'], true);
      await f.resetPersonPropertiesForFlags();
      expect((jsonDecode(http.bodies.last) as Map)['person_properties'], isEmpty);
    });
  });

  group('autocapture', () {
    const btn = TapElement('b', label: 'Buy', props: {'id': 'b', 'secret': 's'});

    test('disabled by default and honours the exclusion marker', () {
      expect(Autocapture(_core(), const AutocaptureConfig()).tap([btn], 0, 0), isNull);
      final on = Autocapture(_core(), const AutocaptureConfig(enabled: true));
      expect(on.tap([btn, const TapElement('root', tag: 'lc-no-capture')], 0, 0), isNull);
      expect(on.tap([btn], 0, 0), isNotNull);
    });

    test('ignore labels, max elements, allow-list, no input values', () {
      final a = Autocapture(_core(),
          const AutocaptureConfig(enabled: true, ignoreLabels: {'skip'}, maxElements: 2, propsAllowList: {'id'}));
      final e = a.tap([btn, const TapElement('skip'), const TapElement('c'), const TapElement('d')], 1, 1)!;
      final els = (_props(e)['\$elements'] as List).cast<Map<String, dynamic>>();
      expect(els, hasLength(2));
      expect(els[0]['tag_name'], 'b');
      expect(els[0]['attr__id'], 'b');
      expect(els[0], isNot(contains('attr__secret')));
      expect(_props(e)['\$el_text'], 'Buy');
      final input = a.tap([const TapElement('field', label: 'hunter2', isInput: true)], 1, 1)!;
      expect(_props(input)['\$el_text'], '');
      expect(_props(a.change([const TapElement('sw')])!)['\$event_type'], 'change');
    });

    test('rage taps fire once after minTaps; far taps and disabled config do not', () {
      final names = <String>[];
      final c = _core();
      c.onCaptured((e) => names.add(e['event'] as String));
      final a = Autocapture(c, const AutocaptureConfig(enabled: true));
      for (var i = 0; i < 3; i++) {
        a.tap([btn], 10, 10);
      }
      expect(names.where((n) => n == '\$autocapture'), hasLength(3));
      expect(names.where((n) => n == '\$rageclick'), hasLength(1));
      final far = Autocapture(c, const AutocaptureConfig(enabled: true));
      for (var i = 0; i < 3; i++) {
        far.tap([btn], i * 100.0, 0);
      }
      final off = Autocapture(c, const AutocaptureConfig(enabled: true, rageTap: RageTapConfig(enabled: false)));
      for (var i = 0; i < 4; i++) {
        off.tap([btn], 1, 1);
      }
      expect(names.where((n) => n == '\$rageclick'), hasLength(1));
    });
  });

  group('replay privacy', () {
    const tree = WireSnapshot(
        'S',
        10,
        10,
        WireNode(WireKind.view, 0, 0, 10, 10, children: [
          WireNode(WireKind.input, 0, 0, 5, 5, text: 'typed'),
          WireNode(WireKind.input, 0, 0, 5, 5, text: 'shown', unmask: true),
          WireNode(WireKind.input, 0, 0, 5, 5, text: 'pw', sensitive: true, unmask: true),
          WireNode(WireKind.image, 0, 0, 5, 5),
          WireNode(WireKind.image, 0, 0, 5, 5, unmask: true),
        ]));

    test('inputs masked by default; unmask and maskAllTextInputs=false relax it; sensitive never', () {
      final def = jsonEncode(fullSnapshotEvent(tree, mask: true, ms: 0));
      expect(def, isNot(contains('typed')));
      expect(def, contains('shown')); // explicit unmask
      final open = jsonEncode(fullSnapshotEvent(tree, mask: true, ms: 0, maskInputs: false));
      expect(open, contains('typed'));
      expect(open, isNot(contains('"pw"')));
      expect(jsonEncode(fullSnapshotEvent(tree, mask: true, ms: 0)).split('data-lc-mask').length - 1, 1);
      expect(
          jsonEncode(fullSnapshotEvent(tree, mask: true, ms: 0, maskImages: false)), isNot(contains('data-lc-mask')));
    });
  });
}
