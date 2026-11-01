import 'package:flutter/rendering.dart' show RenderView;
import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// Wrap anything whose text must never appear in replay, even with `maskTextContent: false`.
class LucidaSensitive extends StatelessWidget {
  const LucidaSensitive({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// Never shows this subtree in replay (text dropped, inputs and images masked). Wins over [LucidaUnmask] at any depth.
class LucidaMask extends StatelessWidget {
  const LucidaMask({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// Shows text, input values (never obscured ones or [LucidaSensitive]) and images of this subtree in replay even when the
/// global masks are on.
class LucidaUnmask extends StatelessWidget {
  const LucidaUnmask({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// Walks the element tree into a [WireSnapshot] for [ReplayRecorder]. Privacy: [EditableText] (every text field)
/// contributes geometry only unless [maskAllTextInputs] is false; `obscureText` fields, [LucidaMask] and
/// [LucidaSensitive] subtrees never carry their text. Frames are taken
/// from each element's [RenderBox] relative to its nearest rendered ancestor.
///
/// Tested with `flutter test` (test/plugin_test.dart); the encoding and recorder loop are covered in lucida_core.
class FlutterWidgetTree implements WidgetTreeSource {
  FlutterWidgetTree(
      {this.maxDepth = 60, this.maxNodes = 1500, this.maskPlatformViews = true, this.maskAllTextInputs = true});
  final int maxDepth;
  final int maxNodes;

  /// Native platform views (maps, webviews, ads) cannot be read; true keeps only their frame.
  final bool maskPlatformViews;

  /// False reads the visible value of non-obscured text fields; pass the same value as [ReplayRecorder.maskAllTextInputs].
  final bool maskAllTextInputs;

  @override
  WireSnapshot? snapshot(String screen) {
    final root = WidgetsBinding.instance.rootElement;
    // The root element renders the RenderView (not a RenderBox); its size is the screen in logical px.
    final ro = root?.renderObject;
    final size = ro is RenderView ? ro.size : (ro is RenderBox && ro.hasSize ? ro.size : null);
    if (root == null || size == null) return null;
    var budget = maxNodes;

    // Only render-object elements become nodes (a component's `renderObject` is its descendant's, so counting
    // those would repeat one box per wrapper). Component widgets pass their meaning down to the first box below.
    WireNode? visit(Element e, Offset origin, bool sensitive, WireKind? pending, bool inInput, int depth, bool unmasked,
        String? pendingValue) {
      if (budget <= 0 || depth > maxDepth) return null;
      final w = e.widget;
      final sens = sensitive || w is LucidaSensitive || w is LucidaMask || (maskPlatformViews && _isPlatformView(w));
      final unmask = unmasked || w is LucidaUnmask;
      final input = inInput || w is EditableText; // the value is read only via [maskAllTextInputs]
      var want = pending;
      var value = pendingValue;
      if (w is EditableText) {
        want = WireKind.input;
        value = maskAllTextInputs || sens || w.obscureText ? null : w.controller.text;
      } else if (w is Image) {
        want = WireKind.image;
      } else if (w is Scrollable) {
        want = WireKind.scroll;
      }
      final ro = e.renderObject;
      final hasBox = e is RenderObjectElement && ro is RenderBox && ro.hasSize && ro.attached;
      var childOrigin = origin;
      var kind = WireKind.view;
      String? text;
      Rect frame = Rect.zero;
      if (hasBox) {
        final at = ro.localToGlobal(Offset.zero);
        frame = (at - origin) & ro.size;
        childOrigin = at;
        if (w is RichText) {
          kind = WireKind.label;
          text = w.text.toPlainText();
        } else {
          kind = want ?? WireKind.view;
        }
      }
      final kids = <WireNode>[];
      e.visitChildElements((c) {
        final n =
            visit(c, childOrigin, sens, hasBox ? null : want, input, hasBox ? depth + 1 : depth, unmask, hasBox ? null : value);
        if (n != null) kids.add(n);
      });
      if (!hasBox) {
        // Elements without geometry (inherited widgets, builders) are transparent: hoist their children.
        return kids.length == 1 ? kids.first : (kids.isEmpty ? null : WireNode(WireKind.view, 0, 0, 0, 0, children: kids));
      }
      budget--;
      return WireNode(kind, frame.left, frame.top, frame.width, frame.height,
          text: sens ? null : (input ? (kind == WireKind.input ? value : null) : text), sensitive: sens, unmask: unmask, children: kids);
    }

    final tree = visit(root, Offset.zero, false, null, false, 0, false, null);
    if (tree == null) return null;
    return WireSnapshot(screen, size.width, size.height, tree);
  }
}

bool _isPlatformView(Widget w) => w is AndroidView || w is UiKitView || w is HtmlElementView;
