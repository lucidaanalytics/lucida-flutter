import 'dart:convert';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

import 'guides_test.dart' show FakePresenter;

class StateHttp implements HttpPort {
  final calls = <(String, String?)>[];
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    calls.add(('$method $url', body));
    if (url.contains('/v1/guides')) {
      return const HttpResult(200, '''
{"guides":[
  {"id":"g-held","name":"H","kind":"modal","held_out":true,"conditions":{"holdout_pct":50,"ab_group":"x"},"steps":[]},
  {"id":"g-twice","name":"T","kind":"modal","conditions":{"frequency":{"max_views":2}},"steps":[{"id":"a"}]}
]}''');
    }
    if (url.contains('/v1/guide-state')) return const HttpResult(200, '{"state":{"lc_guide_progress":{"t":1}}}');
    return const HttpResult(200);
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 1, 12);

  test('schedule window and device-time recurrence (G241)', () {
    expect(GuideRules.scheduleOk({'end': '2026-11-01T12:00:00.000Z'}, now), isFalse);
    expect(GuideRules.scheduleOk({'start': '2026-11-01T11:00:00+00:00'}, now), isTrue);
    final local = now.toLocal();
    expect(GuideRules.scheduleOk({'days': [local.weekday % 7]}, now), isTrue);
    expect(GuideRules.scheduleOk({'days': [(local.weekday + 1) % 7]}, now), isFalse);
    expect(GuideRules.scheduleOk({'hours': {'from': local.hour, 'to': local.hour + 1}}, now), isTrue);
    // A zone-pinned recurrence was decided by the gateway.
    expect(GuideRules.scheduleOk({'days': [(local.weekday + 1) % 7], 'timezone': 'Asia/Tokyo'}, now), isTrue);
    expect(GuideRules.scheduleOk(null, now), isTrue);
  });

  test('frequency caps and merged guide state', () {
    final ms = now.millisecondsSinceEpoch;
    final f = {'max_views': 2, 'per_days': 7};
    expect(GuideRules.frequencyOk(f, [ms - 10 * 86400000, ms - 1000], now), isTrue);
    expect(GuideRules.frequencyOk(f, [ms - 2000, ms - 1000], now), isFalse);
    expect(GuideRules.frequencyOk({}, [1], now), isFalse, reason: 'omitted: once per lifetime');
    final m = GuideRules.merged({
      'lc_guide_progress': {'t': 2},
      'lc_guide_views': {
        'g': [1]
      }
    }, {
      'g': [1, 5],
      'h': [3]
    });
    expect(m['lc_guide_progress'], {'t': 2});
    expect(m['lc_guide_views'], {
      'g': [1, 5],
      'h': [3]
    });
  });

  test('a held-out guide never shows; a repeatable one shows up to its cap, once per screen visit', () async {
    final http = StateHttp();
    final p = FakePresenter()..tap = (_) => null;
    final events = <String>[];
    final core = Core(CoreConfig(
      apiKey: 'lc_pk_test',
      apiHost: 'https://ingest.test/',
      http: http,
      store: MemoryStore(),
      libName: 'lucida-dart',
      libVersion: '0.1.0',
      flushIntervalMs: 60000,
      random: () => 0,
    ))
      ..onCaptured((e) => events.add(e['event'] as String));
    final g = GuidesService(core, GuidesConfig(enabled: true, presenter: p), (_) => false, now: () => now);
    await g.reload();
    expect(http.calls.firstWhere((c) => c.$1.contains('/v1/guides')).$1, contains('tz_offset='));
    g
      ..show('Home')
      ..show('Home')
      ..show('Settings')
      ..show('Home');
    expect(p.shown.map((s) => s.$1), ['g-twice', 'g-twice']);
    expect(events.where((e) => e == '\$guide_holdout').length, 1);
    await g.syncViews({
      'g-twice': [1]
    });
    final put = jsonDecode(http.calls.lastWhere((c) => c.$1.contains('/v1/guide-state')).$2!) as Map;
    expect((put['state'] as Map)['lc_guide_progress'], {'t': 1});
    expect(((put['state'] as Map)['lc_guide_views'] as Map).containsKey('g-twice'), isTrue);
  });
}
