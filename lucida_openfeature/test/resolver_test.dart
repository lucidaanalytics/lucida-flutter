import 'dart:convert';
import 'dart:io';

import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_openfeature/src/resolver.dart';
import 'package:test/test.dart';

class _Http implements HttpPort {
  final bodies = <String>[];
  int status = 200;
  String response =
      '{"flags":{"live":{"value":"b","variant":"b","reason":"condition_match","condition_index":2}},"request_id":"r9"}';
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    if (body != null) bodies.add(body);
    return HttpResult(status, response);
  }
}

Lucida _lucida(_Http h, {Map<String, dynamic> fallbacks = const {}}) => Lucida(
      CoreConfig(
        apiKey: 'lc_pk_x',
        apiHost: 'https://ingest.test/',
        http: h,
        store: MemoryStore(),
        now: () => 1760000000000,
        flushAt: 100,
        flushIntervalMs: 60000,
        random: () => 0,
      ),
      appVersion: '1',
      flagOptions: FlagOptions(fallbacks: fallbacks),
    );

void main() {
  test('reason table matches testdata/openfeature/reasons.json', () {
    final dir = Platform.environment['LUCIDA_TESTDATA'] ?? '../../../testdata';
    final root = jsonDecode(File('$dir/openfeature/reasons.json').readAsStringSync()) as Map;
    (root['reasons'] as Map).forEach((raw, v) {
      expect(openFeatureReason(raw as String, variantValue: false), (v as Map)['reason'], reason: raw);
      if (v['variant_reason'] != null) {
        expect(openFeatureReason(raw, variantValue: true), v['variant_reason'], reason: raw);
      }
    });
    expect(openFeatureReason('brand_new', variantValue: false), 'UNKNOWN');
  });

  test('served flag carries reason and metadata', () async {
    final l = _lucida(_Http());
    await LucidaResolver(l).setContext({'targetingKey': 'u1', 'plan': 'pro'});
    final r = LucidaResolver(l).resolve<String>('live', 'd', (v) => v is String ? v : null);
    expect(r.value, 'b');
    expect(r.reason, 'SPLIT');
    expect(r.metadata, {'lucidaReason': 'condition_match', 'evaluatedLocally': false, 'conditionIndex': 2, 'requestId': 'r9'});
  });

  test('fallback resolves with DEFAULT and no error code', () async {
    final h = _Http()..status = 500;
    final l = _lucida(h, fallbacks: {'live': 'fb'});
    await LucidaResolver(l).setContext({'targetingKey': 'u1'});
    final r = LucidaResolver(l).resolve<String>('live', 'd', (v) => v is String ? v : null);
    expect(r.value, 'fb');
    expect(r.reason, 'DEFAULT');
    expect(r.errorCode, isNull);
    expect(r.metadata['lucidaReason'], 'fallback');
  });

  test('missing flag is FLAG_NOT_FOUND; wrong type is TYPE_MISMATCH', () async {
    final l = _lucida(_Http());
    await LucidaResolver(l).setContext({'targetingKey': 'u1'});
    final res = LucidaResolver(l);
    expect(res.resolve<bool>('nope', false, (v) => v is bool ? v : null).errorCode, 'FLAG_NOT_FOUND');
    expect(res.resolve<bool>('live', false, (v) => v is bool ? v : null).errorCode, 'TYPE_MISMATCH');
  });

  test('context splits groups, group properties and person properties', () async {
    final h = _Http();
    final l = _lucida(h);
    await LucidaResolver(l).setContext({
      'targetingKey': 'u1',
      'plan': 'pro',
      'groups': {'org': 'acme'},
      'groupProperties': {'org': {'size': 5}},
    });
    final req = jsonDecode(h.bodies.last) as Map;
    expect(req['person_properties'], {'plan': 'pro'});
    expect(req['groups'], {'org': 'acme'});
  });

  test('track maps to capture with \$value', () async {
    final h = _Http();
    final l = _lucida(h);
    LucidaResolver(l).track('purchase', details: {'sku': 'a'}, value: 9.5);
    await l.core.flush();
    final ev = ((jsonDecode(h.bodies.last) as Map)['batch'] as List).first as Map;
    expect(ev['event'], 'purchase');
    expect(ev['properties']['\$value'], 9.5);
    expect(ev['properties']['sku'], 'a');
  });
}
