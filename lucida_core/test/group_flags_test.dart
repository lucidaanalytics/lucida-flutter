import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class _Http implements HttpPort {
  int calls = 0;
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    calls++;
    return const HttpResult(200, '{}');
  }
}

void main() {
  test('local evaluation reads group properties without a server call', () async {
    final http = _Http();
    final core = Core(CoreConfig(
      apiKey: 'lc_pk_x',
      apiHost: 'https://ingest.test/',
      http: http,
      store: MemoryStore(),
      libName: 'lucida-dart',
      libVersion: '0.1.0',
      flushIntervalMs: 60000,
      random: () => 0,
    ));
    final flags = Flags(core, definitions: [
      {
        'key': 'enterprise',
        'type': 'boolean',
        'active': true,
        'salt': 's',
        'aggregation': {'kind': 'person'},
        'conditions': [
          {
            'rollout_pct': 100,
            'filters': [
              {'type': 'group', 'group_type': 'company', 'key': 'tier', 'op': 'gte', 'value': 2}
            ],
          }
        ],
      }
    ]);
    await flags.reload();
    expect(flags.isEnabled('enterprise'), isFalse);
    await flags.setGroupPropertiesForFlags('company', {'tier': 3});
    expect(flags.isEnabled('enterprise'), isTrue);
    await flags.resetGroupPropertiesForFlags();
    expect(flags.isEnabled('enterprise'), isFalse);
    expect(http.calls, 0);
  });
}
