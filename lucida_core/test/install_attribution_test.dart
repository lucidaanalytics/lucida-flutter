import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class _Http implements HttpPort {
  _Http(this.statuses);
  final List<int> statuses;
  final List<String> contentTypes = [];
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    contentTypes.add(headers['Content-Type'] ?? '');
    final s = statuses.length > 1 ? statuses.removeAt(0) : statuses.first;
    return HttpResult(s, '{"attribution":true,"orgId":1,"campaignId":2,"adGroupId":3,"keywordId":4,"adId":5}');
  }
}

Core _core(MemoryStore store, List<String> names) {
  final c = Core(CoreConfig(
      apiKey: 'k', apiHost: 'https://h.test/', http: _Http([200]), store: store, libName: 'lucida-dart', libVersion: '0.1.0',
      now: () => 1760000000000, flushAt: 100, random: () => 0));
  c.onCaptured((e) => names.add(e['event'] as String));
  return c;
}

void main() {
  test('parses referrer', () {
    final p = installReferrerProps('utm_source=google-play&utm_campaign=a%20b&gclid=G1&junk', clickTs: 1, beginTs: 2);
    expect(p['\$install_store'], 'google_play');
    expect(p['\$utm_campaign'], 'a b');
    expect(p['\$gclid'], 'G1');
    expect(p['\$install_begin_ts'], 2);
    expect(p.containsKey('\$utm_term'), isFalse);
  });

  test('maps ASA response', () {
    final p = appStoreInstallProps('{"attribution":true,"orgId":9,"campaignId":2,"keywordId":4,"adGroupId":3}');
    expect(p['\$utm_source'], 'apple_search_ads');
    expect(p['\$utm_campaign'], '2');
    expect(p['\$utm_term'], '4');
    expect(p['\$utm_content'], '3');
    expect(p['\$asa_org_id'], '9');
    expect(appStoreInstallProps(null), {'\$install_store': 'app_store'});
    expect(appStoreInstallProps('{"attribution":false}')['\$install_adservices_attribution'], false);
  });

  test('ios token retries 404 and posts text/plain', () async {
    final h = _Http([404, 200]);
    final src = installSourceFrom(() async => {'platform': 'ios', 'token': 't'}, h, retryDelay: Duration.zero);
    final p = await src();
    expect(h.contentTypes, ['text/plain', 'text/plain']);
    expect(p['\$asa_campaign_id'], '2');
  });

  test('android source and failure degrade', () async {
    final a = await installSourceFrom(
        () async => {'platform': 'android', 'referrer': 'utm_source=x', 'clickTs': 5, 'beginTs': 6}, _Http([200]))();
    expect(a['\$utm_source'], 'x');
    expect(await installSourceFrom(() async => throw Exception('no plugin'), _Http([200]))(), isEmpty);
  });

  test('install is sent once, with attribution', () async {
    final store = MemoryStore();
    final names = <String>[];
    final props = <Map>[];
    final src = () async => {'\$install_store': 'google_play', '\$utm_source': 'x'};
    final c1 = _core(store, names)..onCaptured((e) => props.add(e['properties'] as Map));
    Lifecycle(c1, version: '1.0', installSource: src).launched();
    Lifecycle(_core(store, names), version: '1.0', installSource: src).launched();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(names.where((n) => n == '\$app_installed').length, 1);
    expect(props.firstWhere((p) => p.containsKey('\$utm_source'))['\$utm_source'], 'x');
  });
}
