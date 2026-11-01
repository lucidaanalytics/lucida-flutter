import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// Wrap the app once (above `MaterialApp`) to allow screenshot-mode replay: [FlutterScreenshots] draws this boundary.
class LucidaReplayBoundary extends StatelessWidget {
  const LucidaReplayBoundary({super.key, required this.child});
  final Widget child;

  static final GlobalKey _boundary = GlobalKey(debugLabel: 'LucidaReplayBoundary');

  @override
  Widget build(BuildContext context) => RepaintBoundary(key: _boundary, child: child);
}

/// [ScreenshotSource] over [LucidaReplayBoundary]: takes the layer synchronously (`toImageSync`, same frame as the tree
/// walk), paints the plan on a [ui.PictureRecorder] canvas (mask, unmask restored from the original, sensitive last)
/// and only then encodes PNG, so masked pixels never exist in what leaves the device.
/// Platform views (maps, webviews) are not part of the layer tree and come out blank.
class FlutterScreenshots implements ScreenshotSource {
  FlutterScreenshots({this.maskColor = const Color(0xFF000000)});
  final Color maskColor;

  @override
  Future<String?> capture(ScreenshotMaskPlan plan) async {
    final img = await maskedImage(plan);
    if (img == null) return null;
    try {
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      return bytes == null ? null : base64Encode(bytes.buffer.asUint8List());
    } finally {
      img.dispose();
    }
  }

  /// The masked frame before encoding (tests read its pixels); null without a laid-out [LucidaReplayBoundary].
  Future<ui.Image?> maskedImage(ScreenshotMaskPlan plan) async {
    final ro = LucidaReplayBoundary._boundary.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize || !ro.attached) return null;
    final ui.Image raw;
    try {
      raw = ro.toImageSync(); // logical pixels (pixelRatio 1): the plan's coordinates
    } catch (_) {
      return null; // not painted yet
    }
    final origin = ro.localToGlobal(Offset.zero);
    Rect at(MaskRect m) => Rect.fromLTWH(m.x - origin.dx, m.y - origin.dy, m.width, m.height);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final plain = Paint();
    final fill = Paint()..color = maskColor;
    canvas.drawImage(raw, Offset.zero, plain);
    for (final m in plan.mask) {
      canvas.drawRect(at(m), fill);
    }
    for (final m in plan.unmask) {
      canvas
        ..save()
        ..clipRect(at(m))
        ..drawImage(raw, Offset.zero, plain)
        ..restore();
    }
    for (final m in plan.sensitive) {
      canvas.drawRect(at(m), fill);
    }
    final picture = rec.endRecording();
    try {
      return await picture.toImage(raw.width, raw.height);
    } finally {
      picture.dispose();
      raw.dispose();
    }
  }
}
