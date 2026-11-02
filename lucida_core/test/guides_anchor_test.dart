import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

import 'guides_test.dart' show GuidesHttp;

/// N-DAP-10 / N-DAP-7 / N-DAP-9: anchored steps by native_id (ValueKey), carousel paging, theme tokens, placement.
class FakeAnchored implements AnchoredGuidePresenter {
  final plain = <(String, int, List<String>)>[];
  final anchored = <(int, GuideAnchor)>[];
  bool missing = false;
  GuideButton? Function(List<GuideButton>)? tap;

  @override
  void present(MobileGuide guide, int step, List<GuideButton> buttons, void Function(GuideButton?) onAction) {
    plain.add((guide.id, step, buttons.map((b) => b.label).toList()));
    final t = tap;
    if (t != null) onAction(t(buttons));
  }

  @override
  void presentAnchored(
    MobileGuide guide,
    int step,
    List<GuideButton> buttons,
    GuideAnchor anchor,
    void Function() onMissing,
    void Function(GuideButton?) onAction,
  ) {
    anchored.add((step, anchor));
    if (missing) {
      onMissing();
      return present(guide, step, buttons, onAction);
    }
    final t = tap;
    if (t != null) onAction(t(buttons));
  }

  @override
  void open(Uri url) {}
}

({GuidesService g, FakeAnchored p, List<Map<String, dynamic>> events}) setup(String json, {double Function()? random}) {
  final p = FakeAnchored();
  final events = <Map<String, dynamic>>[];
  final core = Core(
    CoreConfig(
      apiKey: 'lc_pk_test',
      apiHost: 'https://ingest.test/',
      http: GuidesHttp(json),
      store: MemoryStore(),
      libName: 'lucida-dart',
      libVersion: '0.1.0',
      flushIntervalMs: 60000,
      random: () => 0,
    ),
  )..onCaptured((e) => events.add(Map<String, dynamic>.from(e)));
  return (
    g: GuidesService(core, GuidesConfig(enabled: true, presenter: p), (_) => false, random: random),
    p: p,
    events: events
  );
}

void main() {
  test('tour steps anchor by native_id; steps without one show plain', () async {
    final t = setup(
      '{"guides":[{"id":"t","name":"T","kind":"tour","conditions":{},"steps":[{"id":"a","title":"A","native_id":"checkout","placement":"top","wait_ms":500},{"id":"b","title":"B"}]}]}',
    );
    await t.g.reload();
    t.p.tap = (b) => b.first;
    t.g.show('Home');
    expect(t.p.anchored, [(0, const GuideAnchor('checkout', 'top', 500, false))]);
    expect(t.p.plain.map((x) => x.$2), [1]);
  });

  test('a missing target emits \$guide_target_missing and falls back', () async {
    final t = setup(
      '{"guides":[{"id":"tt","name":"T","kind":"tooltip","conditions":{},"steps":[{"id":"a","native_id":"gone","wait_ms":99999}]}]}',
    );
    t.p.missing = true;
    await t.g.reload();
    t.g.show('Home');
    expect(t.p.anchored.single.$2.waitMs, 15000);
    expect(t.p.plain.map((x) => x.$1), ['tt']);
    final ev = t.events.firstWhere((e) => e['event'] == '\$guide_target_missing');
    expect((ev['properties'] as Map)['selector'], 'gone');
  });

  test('hotspots need a native_id', () async {
    final t = setup(
      '{"guides":[{"id":"h0","name":"H","kind":"hotspot","conditions":{},"steps":[{"id":"a","selector":"#web"}]},{"id":"h1","name":"H","kind":"hotspot","conditions":{},"steps":[{"id":"a","native_id":"bell"}]}]}',
    );
    await t.g.reload();
    t.g.show('Home');
    expect(t.p.anchored.map((x) => x.$2.hotspot), [true]);
  });

  test('carousel pages with Back and Next', () async {
    final t = setup(
      '{"guides":[{"id":"c","name":"C","kind":"carousel","conditions":{},"steps":[{"id":"1","title":"One"},{"id":"2","title":"Two"}]}]}',
    );
    await t.g.reload();
    final taps = ['Next', 'Back', 'Next', 'Done'];
    t.p.tap = (bs) {
      final want = taps.removeAt(0);
      return bs.firstWhere((b) => b.label == want);
    };
    t.g.show('Home');
    expect(t.p.plain.map((x) => x.$2), [0, 1, 0, 1]);
    expect(t.p.plain[1].$3, ['Back', 'Done', 'Dismiss']);
  });

  test('theme tokens: light, dark, validation', () {
    final a = <String, dynamic>{
      'tokens': {'background': '#ffffff', 'accent': 'javascript:x', 'radius': 8},
      'dark': {
        'tokens': {'background': '#000'},
      },
      'font_family': 'Inter',
    };
    expect(GuideTheme.tokens(a, systemDark: false).background, '#ffffff');
    expect(GuideTheme.tokens(a, systemDark: true).background, '#000');
    expect(GuideTheme.tokens(a, systemDark: false).accent, isNull);
    expect(GuideTheme.tokens(a, systemDark: false).radius, 8);
    expect(GuideTheme.tokens({...a, 'theme_mode': 'light'}, systemDark: true).background, '#ffffff');
    expect(GuideTokens.argb('#f00'), 0xFFFF0000);
  });

  test('queued guides go first and skip sampling; exclusions match screen names', () async {
    final t = setup(
        '{"guides":[{"id":"plain","name":"P","kind":"modal","conditions":{},"steps":[{"id":"a"}]},{"id":"q","name":"Q","kind":"modal","queued":true,"conditions":{"sample_pct":1},"steps":[{"id":"a"}]},{"id":"x","name":"X","kind":"modal","conditions":{"exclude_url_patterns":["Check*"]},"steps":[{"id":"a"}]}]}',
        random: () => 0.99);
    final g = t.g;
    await g.reload();
    t.p.tap = (_) => null;
    g.show('Checkout');
    expect(t.p.plain.map((x) => x.$1), ['q', 'plain']); // queued first despite 1% sampling; x excluded here
    expect(GuidesService.excluded('Checkout', ['Check*']), isTrue);
    expect(GuidesService.excluded('Home', ['Check*', '']), isFalse);
    expect(GuidesService.excluded('a.b', ['a?b']), isFalse);
    t.p.plain.clear();
    g.show('Home');
    expect(t.p.plain.map((x) => x.$1), ['x']);
  });

  test('placement: below, above when no room, clamped', () {
    const bounds = (0.0, 0.0, 400.0, 800.0);
    expect(GuidePlacement.origin(200, 100, (100, 100, 50, 40), bounds, null), (25.0, 148.0));
    expect(GuidePlacement.origin(200, 100, (100, 740, 50, 40), bounds, null).$2, 632);
    expect(GuidePlacement.origin(200, 100, (380, 100, 20, 20), bounds, null).$1, 188);
  });
}
