/// Screenshot-mode replay, platform-free: the mask plan derived from a [WireSnapshot] (same rules as the iOS and
/// Android SDKs) and the rrweb FullSnapshot that carries one already-masked image. The pixels come from a
/// [ScreenshotSource] (the Flutter binding draws a `RepaintBoundary`), which paints the plan BEFORE encoding.
library;

import 'wireframe.dart';

/// Absolute rectangle in logical pixels (root coordinates).
class MaskRect {
  const MaskRect(this.x, this.y, this.width, this.height);
  final double x, y, width, height;

  @override
  bool operator ==(Object other) =>
      other is MaskRect && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'MaskRect($x, $y, $width, $height)';
}

/// Paint order: [mask] first, then [unmask] regions restored from the original pixels, then [sensitive] last (always wins).
class ScreenshotMaskPlan {
  const ScreenshotMaskPlan(this.mask, this.unmask, this.sensitive);
  final List<MaskRect> mask, unmask, sensitive;
}

/// Port: one frame of the screen with [plan] painted over it before encoding; base64 PNG, or null when nothing could
/// be drawn. Implementations must take the pixels synchronously on call (before their first `await`), so the frame
/// matches the tree walk the plan came from.
abstract class ScreenshotSource {
  Future<String?> capture(ScreenshotMaskPlan plan);
}

/// Inputs, images and (non-empty) text are painted over unless the global switch is off or the node is unmasked;
/// sensitive nodes (obscured fields, `LucidaMask`, `LucidaSensitive`, platform views) are always painted over.
ScreenshotMaskPlan screenshotPlan(WireSnapshot s,
    {required bool mask, bool maskInputs = true, bool maskImages = true}) {
  final m = <MaskRect>[], u = <MaskRect>[], sens = <MaskRect>[];
  void walk(WireNode n, double ox, double oy, bool isRoot) {
    final left = isRoot ? 0.0 : ox + n.x;
    final top = isRoot ? 0.0 : oy + n.y;
    final r = MaskRect(left, top, n.width, n.height);
    if (n.sensitive) {
      sens.add(r);
    } else {
      final hide = switch (n.kind) {
        WireKind.input => maskInputs,
        WireKind.image => maskImages,
        _ => mask && (n.text ?? '').isNotEmpty,
      };
      if (n.unmask) {
        u.add(r);
      } else if (hide) {
        m.add(r);
      }
    }
    for (final c in n.children) {
      walk(c, left, top, false);
    }
  }

  walk(s.root, 0, 0, true);
  return ScreenshotMaskPlan(m, u, sens);
}

/// FullSnapshot whose body holds one `<img>` (data: PNG, already masked on device); ids: body 3, img 4.
Map<String, dynamic> screenshotSnapshotEvent(WireSnapshot s, String pngBase64, int ms) {
  final w = s.width.round(), h = s.height.round();
  final img = {
    'type': 2,
    'id': 4,
    'tagName': 'img',
    'attributes': {
      'src': 'data:image/png;base64,$pngBase64',
      'style': 'width:${w}px;height:${h}px',
      'data-lc-view': 'screenshot'
    },
    'childNodes': <Map<String, dynamic>>[],
  };
  final body = {
    'type': 2,
    'id': 3,
    'tagName': 'body',
    'attributes': {'class': 'lc-wf lc-wf-screenshot', 'style': 'position:relative;margin:0;width:${w}px;height:${h}px'},
    'childNodes': [img],
  };
  final html = {
    'type': 2,
    'id': 2,
    'tagName': 'html',
    'attributes': <String, dynamic>{},
    'childNodes': [body]
  };
  return {
    'type': 2,
    'timestamp': ms,
    'data': {
      'node': {
        'type': 0,
        'id': 1,
        'childNodes': [html]
      },
      'initialOffset': {'left': 0, 'top': 0}
    },
  };
}
