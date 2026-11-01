import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// Marks a subtree for autocapture: `noCapture` excludes it (and everything below) entirely; `name` / `props` describe
/// the element (props reach the event only if listed in `AutocaptureConfig.propsAllowList`).
class LucidaMark extends SingleChildRenderObjectWidget {
  const LucidaMark({
    super.key,
    this.name,
    this.noCapture = false,
    this.props = const {},
    super.child,
  });
  final String? name;
  final bool noCapture;
  final Map<String, String> props;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMark(name, noCapture, props);

  @override
  void updateRenderObject(BuildContext context, _RenderMark ro) => ro
    ..name = name
    ..noCapture = noCapture
    ..props = props;
}

class _RenderMark extends RenderProxyBox {
  _RenderMark(this.name, this.noCapture, this.props);
  String? name;
  bool noCapture;
  Map<String, String> props;
}

/// Wrap the app (below `MaterialApp`'s navigator is fine) to record `$autocapture` taps for `client.autocapture`.
/// The tapped chain is read from the hit-test path: paragraph text (labels), images, text fields (geometry only, the
/// value is never read) and [LucidaMark]s. Disabled unless `AutocaptureConfig.enabled`.
class LucidaAutocapture extends StatelessWidget {
  const LucidaAutocapture({
    super.key,
    required this.client,
    required this.child,
  });
  final Lucida client;
  final Widget child;

  List<TapElement> _chain(HitTestResult hit) {
    final out = <TapElement>[];
    for (final e in hit.path) {
      final t = e.target;
      if (t is _RenderMark) {
        out.add(
          TapElement(
            t.name ?? 'mark',
            tag: t.noCapture ? client.autocapture.cfg.noCaptureMarker : null,
            props: t.props,
          ),
        );
      } else if (t is RenderEditable) {
        out.add(const TapElement('textfield', isInput: true));
      } else if (t is RenderParagraph) {
        out.add(TapElement('text', label: t.text.toPlainText()));
      } else if (t is RenderImage) {
        out.add(const TapElement('image'));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerUp: (e) {
      if (!client.autocapture.cfg.enabled) return;
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        hit,
        e.position,
        View.of(context).viewId,
      );
      client.autocapture.tap(_chain(hit), e.position.dx, e.position.dy);
    },
    child: child,
  );
}
