/// Platform-neutral wireframe model and its rrweb encoding (same shape as the iOS SDK's `RRWebWireframe`,
/// which `crates/lc-replay` decodes): Meta (type 4, `href` = `app://<screen>`), FullSnapshot (type 2, a DOM-like tree of
/// absolutely positioned divs) and the custom `navigation` event (type 5) read as a URL change.
library;

enum WireKind { view, label, button, image, input, scroll }

/// One widget/render object in platform-neutral form. Frames are in the parent's coordinate space (logical pixels).
class WireNode {
  const WireNode(this.kind, this.x, this.y, this.width, this.height,
      {this.text, this.background, this.sensitive = false, this.unmask = false, this.children = const []});
  final WireKind kind;
  final double x, y, width, height;
  final String? text;

  /// CSS colour, e.g. `#ff8800`.
  final String? background;

  /// Obscured text field, or a widget the app marked sensitive: text is never included.
  final bool sensitive;

  /// The app explicitly allowed this node's text / input value / image (never overrides [sensitive]).
  final bool unmask;
  final List<WireNode> children;
}

class WireSnapshot {
  const WireSnapshot(this.screen, this.width, this.height, this.root);
  final String screen;
  final double width, height;
  final WireNode root;
}

/// Port: produces the current widget tree as a [WireSnapshot]. The Flutter binding (`lucida_flutter`) implements it by
/// walking the element/render tree; tests use a fake. Implementations must never read input values.
abstract class WidgetTreeSource {
  WireSnapshot? snapshot(String screen);
}

/// Every non-space character becomes `*`: layout survives, content does not.
String maskText(String s) => s.replaceAllMapped(RegExp(r'\S'), (_) => '*');

String _fmt(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

Map<String, dynamic> _event(int type, int ms, Map<String, dynamic> data) =>
    {'type': type, 'timestamp': ms, 'data': data};

Map<String, dynamic> metaEvent(WireSnapshot s, int ms) =>
    _event(4, ms, {'href': 'app://${s.screen}', 'width': s.width, 'height': s.height});

Map<String, dynamic> navigationEvent(WireSnapshot s, int ms) => _event(5, ms, {
      'tag': 'navigation',
      'payload': {'url': 'app://${s.screen}'}
    });

/// [mask] stars text unless false; inputs and sensitive nodes never carry text either way.
Map<String, dynamic> fullSnapshotEvent(WireSnapshot s,
    {required bool mask, required int ms, bool maskInputs = true, bool maskImages = true}) {
  var next = 3; // 1 = document, 2 = html
  Map<String, dynamic> build(WireNode n, bool isRoot) {
    final id = next++;
    var style = 'position:${isRoot ? 'relative' : 'absolute'};left:${_fmt(n.x)}px;top:${_fmt(n.y)}px;'
        'width:${_fmt(n.width)}px;height:${_fmt(n.height)}px;overflow:hidden';
    if (n.background != null) style += ';background-color:${n.background}';
    final kids = <Map<String, dynamic>>[];
    final t = n.text;
    // Inputs carry text only when the app turned [maskInputs] off or unmasked the node; sensitive nodes never do.
    final isInput = n.kind == WireKind.input;
    final textMasked = isInput ? (maskInputs && !n.unmask) : (mask && !n.unmask);
    if (t != null && t.isNotEmpty && !n.sensitive) {
      kids.add({'type': 3, 'id': next++, 'textContent': textMasked ? maskText(t) : t});
    }
    for (final c in n.children) {
      kids.add(build(c, false));
    }
    return {
      'type': 2,
      'id': id,
      'tagName': isRoot ? 'body' : 'div',
      'attributes': {
        'class': 'lc-wf lc-wf-${n.kind.name}',
        'style': style,
        'data-lc-view': n.kind.name,
        if (n.kind == WireKind.image && maskImages && !n.unmask) 'data-lc-mask': '',
      },
      'childNodes': kids,
    };
  }

  final body = build(s.root, true);
  final html = {
    'type': 2,
    'id': 2,
    'tagName': 'html',
    'attributes': <String, dynamic>{},
    'childNodes': [body]
  };
  final doc = {
    'type': 0,
    'id': 1,
    'childNodes': [html]
  };
  return _event(2, ms, {
    'node': doc,
    'initialOffset': {'left': 0, 'top': 0}
  });
}

/// Id [fullSnapshotEvent] gives the deepest node containing the point (same numbering), else the root.
int nodeAt(WireSnapshot s, double x, double y) {
  var next = 3;
  var hit = 3;
  void walk(WireNode n, double ox, double oy, bool isRoot) {
    final id = next++;
    final left = isRoot ? 0.0 : ox + n.x;
    final top = isRoot ? 0.0 : oy + n.y;
    if (x >= left && x < left + n.width && y >= top && y < top + n.height) hit = id;
    if ((n.text ?? '').isNotEmpty && !n.sensitive) next++; // the text node takes the next id, before the children
    for (final c in n.children) {
      walk(c, left, top, false);
    }
  }

  walk(s.root, 0, 0, true);
  return hit;
}

/// A tap as an rrweb MouseInteraction Click (type 3, source 2, interaction 2), like the iOS and Android SDKs.
Map<String, dynamic> tapEvent(WireSnapshot s, double x, double y, int ms) =>
    _event(3, ms, {'source': 2, 'type': 2, 'id': nodeAt(s, x, y), 'x': x, 'y': y});
