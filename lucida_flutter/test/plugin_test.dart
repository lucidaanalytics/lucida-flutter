import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_flutter/lucida_flutter.dart';

Iterable<WireNode> _all(WireNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* _all(c);
  }
}

void main() {
  testWidgets('LucidaMask beats LucidaUnmask at any depth; LucidaUnmask shows plain text (LC-EXP-53)', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          LucidaUnmask(child: Text('open text')),
          LucidaUnmask(child: LucidaMask(child: Text('masked text'))),
          LucidaMask(child: LucidaUnmask(child: Text('masked inner'))),
        ]),
      ),
    ));
    final nodes = _all(FlutterWidgetTree().snapshot('Home')!.root).toList();
    final texts = nodes.map((n) => n.text).whereType<String>().toList();
    expect(texts, contains('open text'));
    expect(texts.any((x) => x.contains('masked')), isFalse);
    expect(nodes.where((n) => n.unmask && n.text == 'open text'), isNotEmpty);
  });

  testWidgets('LucidaTouchCapture feeds taps to the recorder and respects captureTouches', (t) async {
    final http = _NoHttp();
    final core = Core(CoreConfig(
      apiKey: 'k', apiHost: 'https://x.test', http: http, store: MemoryStore(),
      libName: 'lucida-dart', libVersion: '0', flushIntervalMs: 60000, random: () => 0,
    ));
    final src = FlutterWidgetTree();
    for (final on in [true, false]) {
      final rec = ReplayRecorder(core, src, captureTouches: on);
      await t.pumpWidget(MaterialApp(home: LucidaTouchCapture(recorder: rec, child: const Scaffold(body: Text('hi')))));
      await t.runAsync(rec.tick);
      http.bodies.clear();
      await t.tapAt(const Offset(10, 10));
      await t.runAsync(() async {
        core.consent.set({'analytics': true, 'replay': true});
        await rec.tick();
      });
      final tapped = http.bodies.any((b) => b.contains('"source":2'));
      expect(tapped, on);
    }
  });

  testWidgets('FlutterWidgetTree keeps labels, never input or sensitive text (LC-EXP-9)', (t) async {
    final c = TextEditingController(text: 'secret@x.com');
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          const Text('Hello Ann'),
          TextField(controller: c),
          const LucidaSensitive(child: Text('4111 1111')),
        ]),
      ),
    ));
    final s = FlutterWidgetTree().snapshot('Home')!;
    expect(s.screen, 'Home');
    expect(s.width, greaterThan(0));
    final nodes = _all(s.root).toList();
    final texts = nodes.map((n) => n.text).whereType<String>().toList();
    expect(texts, contains('Hello Ann'));
    expect(texts.any((x) => x.contains('secret') || x.contains('4111')), isFalse);
    expect(nodes.any((n) => n.kind == WireKind.input), isTrue);
  });

  testWidgets('maskAllTextInputs=false reads plain fields only; obscured and LucidaMask fields stay empty (G77)', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(controller: TextEditingController(text: 'plain value')),
          TextField(controller: TextEditingController(text: 'pw value'), obscureText: true),
          LucidaMask(child: TextField(controller: TextEditingController(text: 'masked value'))),
        ]),
      ),
    ));
    List<String> inputTexts(FlutterWidgetTree src) => _all(src.snapshot('Home')!.root)
        .where((n) => n.kind == WireKind.input)
        .map((n) => n.text)
        .whereType<String>()
        .toList();
    expect(inputTexts(FlutterWidgetTree()), isEmpty); // default stays masked
    final open = inputTexts(FlutterWidgetTree(maskAllTextInputs: false));
    expect(open, ['plain value']);
  });

  testWidgets('DialogGuidePresenter shows a step and reports the tapped button (LC-ENG-15)', (t) async {
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    final g = MobileGuide('g1', 'Tour', 'modal', [GuideStep('s1', 'Welcome', 'Plain text', null)], {});
    final got = <String?>[];
    DialogGuidePresenter(key).present(g, 0, const [GuideButton('Next', 'next'), GuideButton('Dismiss', 'dismiss')], (b) => got.add(b?.label));
    await t.pumpAndSettle();
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('Plain text'), findsOneWidget);
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    expect(got, ['Next']);
    expect(find.text('Welcome'), findsNothing);
  });
}

class _NoHttp implements HttpPort {
  final bodies = <String>[];
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    if (body != null && url.contains('/v1/replay')) bodies.add(body);
    return const HttpResult(200);
  }
}
