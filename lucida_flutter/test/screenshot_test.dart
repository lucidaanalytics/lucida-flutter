import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_flutter/lucida_flutter.dart';

void main() {
  testWidgets('screenshot mode paints text fields over before encoding (G194)', (t) async {
    await t.pumpWidget(LucidaReplayBoundary(
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 300, child: TextField(controller: TextEditingController(text: 'card 4111 1111'))),
          ),
        ),
      ),
    ));
    final snap = FlutterWidgetTree().snapshot('Pay')!;
    final plan = screenshotPlan(snap, mask: true);
    expect(plan.mask, isNotEmpty);
    final shots = FlutterScreenshots(maskColor: const Color(0xFFFF0000));
    final pixels = await t.runAsync(() async {
      final img = await shots.maskedImage(plan);
      final data = await img!.toByteData(format: ui.ImageByteFormat.rawRgba);
      final out = (width: img.width, height: img.height, bytes: data!.buffer.asUint8List());
      img.dispose();
      return out;
    });
    final p = pixels!;
    bool red(double x, double y) {
      final i = (y.floor() * p.width + x.floor()) * 4;
      return p.bytes[i] == 255 && p.bytes[i + 1] == 0 && p.bytes[i + 2] == 0;
    }

    for (final m in plan.mask) {
      expect(red(m.x + m.width / 2, m.y + m.height / 2), isTrue, reason: 'masked rect $m must be painted');
    }
    expect(red(p.width - 2.0, p.height - 2.0), isFalse, reason: 'the empty background is not masked');

    final png = await t.runAsync(() => shots.capture(plan));
    expect(png, isNotEmpty);
  });

  testWidgets('without a LucidaReplayBoundary nothing is captured', (t) async {
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    final got = await t.runAsync(() => FlutterScreenshots().capture(const ScreenshotMaskPlan([], [], [])));
    expect(got, isNull);
  });
}
