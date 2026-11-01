import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_flutter/lucida_flutter.dart';

class _NoHttp implements HttpPort {
  @override
  Future<HttpResult> send(
    String method,
    String url, {
    String? body,
    Map<String, String> headers = const {},
    bool gzip = false,
  }) async => const HttpResult(200);
}

void main() {
  testWidgets(
    'LucidaAutocapture records taps, honours LucidaMark exclusion (LC-EXP-35)',
    (t) async {
      final events = <String>[];
      final texts = <String>[];
      final client = Lucida(
        CoreConfig(
          apiKey: 'k',
          apiHost: 'https://x.test',
          http: _NoHttp(),
          store: MemoryStore(),
          libName: 't',
          libVersion: '0',
          flushAt: 1,
        ),
        appVersion: '1',
        autocaptureConfig: const AutocaptureConfig(
          enabled: true,
          propsAllowList: {'id'},
        ),
      );
      client.core.onCaptured((e) {
        events.add(e['event'] as String);
        texts.add('${(e['properties'] as Map)['\$el_text']}');
      });
      await t.pumpWidget(
        MaterialApp(
          home: LucidaAutocapture(
            client: client,
            child: const Scaffold(
              body: Column(
                children: [
                  LucidaMark(
                    name: 'cta',
                    props: {'id': 'buy'},
                    child: Text('Buy now'),
                  ),
                  LucidaMark(noCapture: true, child: Text('Private')),
                ],
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Buy now'));
      await t.tap(find.text('Private'));
      expect(events, ['\$autocapture']);
      expect(texts.single, 'Buy now');
    },
  );

  testWidgets('LucidaUnmask marks the snapshot node', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LucidaUnmask(child: Text('Hello'))),
      ),
    );
    final s = FlutterWidgetTree().snapshot('Home')!;
    bool any(WireNode n) => n.unmask || n.children.any(any);
    expect(any(s.root), isTrue);
  });
}
