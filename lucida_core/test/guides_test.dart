import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

class FakePresenter implements GuidePresenter {
  final shown = <(String, int, List<String>)>[];
  final opened = <Uri>[];
  GuideButton? Function(List<GuideButton>)? tap;
  @override
  void present(MobileGuide guide, int step, List<GuideButton> buttons, void Function(GuideButton?) onAction) {
    shown.add((guide.id, step, buttons.map((b) => b.label).toList()));
    final t = tap;
    if (t != null) onAction(t(buttons));
  }

  @override
  void open(Uri url) => opened.add(url);
}

class GuidesHttp implements HttpPort {
  GuidesHttp(this.json);
  final String json;
  final urls = <String>[];
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    urls.add('$method $url');
    return url.contains('/v1/guides') ? HttpResult(200, json) : const HttpResult(200);
  }
}

const guidesJson = '''
{"guides":[
  {"id":"g-tour","name":"Tour","kind":"tour","conditions":{"url":"Home","person_filters":[]},"steps":[{"id":"s1","title":"Hi"},{"id":"s2","body":"Last","buttons":[{"label":"Docs","action":"link","url":"https://docs.test/x"}]}]},
  {"id":"g-person","name":"P","kind":"modal","conditions":{"person_filters":[{"key":"plan","op":"eq","value":"pro"}]},"steps":[{"id":"a"}]},
  {"id":"g-hotspot","name":"H","kind":"hotspot","conditions":{},"steps":[{"id":"a","selector":"#x"}]},
  {"id":"g-flag","name":"F","kind":"banner","conditions":{"flag_key":"beta","url":"Set","url_match":"regex"},"steps":[{"id":"b"}]}
]}
''';

({GuidesService g, FakePresenter p, GuidesHttp http, List<String> events}) setup(
    {Set<String> flags = const {}, String json = guidesJson}) {
  final http = GuidesHttp(json);
  final p = FakePresenter();
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
  final g = GuidesService(core, GuidesConfig(enabled: true, presenter: p), flags.contains);
  return (g: g, p: p, http: http, events: events);
}

void main() {
  test('tour on its screen with events and show-once', () async {
    final t = setup();
    t.g.show('Settings'); // nothing loaded yet
    await t.g.reload();
    expect(t.p.shown, isEmpty, reason: "Settings: the tour wants Home, the banner's flag is off");
    final req = t.http.urls.firstWhere((u) => u.contains('/v1/guides'));
    expect(req, startsWith('GET '));
    expect(req, contains('api_key=lc_pk_test'));
    expect(req, contains('distinct_id='));

    t.p.tap = (b) => b.first; // Next, then the link button
    t.g.show('HomeScreen');
    expect(t.p.shown.map((s) => s.$1), ['g-tour', 'g-tour']);
    expect(t.p.shown.map((s) => s.$2), [0, 1]);
    expect(t.p.shown[0].$3, ['Next', 'Dismiss']);
    expect(t.p.shown[1].$3, ['Docs']);
    expect(t.p.opened, [Uri.parse('https://docs.test/x')]);
    expect(t.events.where((e) => e.startsWith('\$guide')),
        ['\$guide_shown', '\$guide_step', '\$guide_step', '\$guide_completed']);

    t.p.shown.clear();
    t.g.show('HomeScreen');
    expect(t.p.shown, isEmpty, reason: 'shown once; person-targeted and hotspot guides never show on mobile');
  });

  test('flag and regex targeting and dismiss', () async {
    final t = setup(flags: {'beta'});
    await t.g.reload();
    t.p.tap = (_) => null; // closed without a button
    t.g.show('Settings');
    expect(t.p.shown.map((s) => s.$1), ['g-flag']);
    expect(t.p.shown[0].$3, ['Dismiss']);
    expect(t.events, contains('\$guide_dismissed'));
  });

  test('preview guides are quiet and once per launch', () async {
    final t = setup(
        json:
            '{"guides":[{"id":"p","name":"P","kind":"modal","preview":true,"conditions":{"person_filters":[{"key":"a"}]},"steps":[{"id":"a"}]}]}');
    await t.g.reload();
    t.p.tap = (b) => b.first;
    t.g.show('Any');
    expect(t.p.shown.map((s) => s.$1), ['p']);
    expect(t.events.where((e) => e.startsWith('\$guide')), isEmpty);
    t.g.show('Any');
    expect(t.p.shown.length, 1);
  });

  test('match modes', () {
    expect(GuidesService.matches('Checkout', 'Check', 'contains'), isTrue);
    expect(GuidesService.matches('Checkout', 'Check', 'exact'), isFalse);
    expect(GuidesService.matches('Checkout', '^Check.*t\$', 'regex'), isTrue);
    expect(GuidesService.matches('Checkout', '(', 'regex'), isFalse);
  });
}
