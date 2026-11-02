import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucida_core/lucida_core.dart';

/// Anchored guide steps in Flutter (N-DAP-10): the step's native_id is the `ValueKey<String>` of the target widget.
/// The bubble is an OverlayEntry that only hit-tests itself (taps elsewhere reach the app) and re-measures the
/// target every 100 ms (scroll, rotation, relayout). A hotspot is a pulsing dot that opens the bubble. A target
/// gone for 2 s (the route changed) ends the step as closed.

/// A resolved `#hex` token as a Color.
Color? guideColor(String? hex) {
  final v = GuideTokens.argb(hex);
  return v == null ? null : Color(v);
}

/// The first mounted element whose widget carries `ValueKey<String>(id)` and has a laid-out box.
Element? findGuideAnchor(String id) {
  Element? hit;
  void visit(Element e) {
    if (hit != null) return;
    final k = e.widget.key;
    if (k is ValueKey<String> && k.value == id) {
      final r = e.renderObject;
      if (r is RenderBox && r.attached && r.hasSize) {
        hit = e;
        return;
      }
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return hit;
}

/// Global rect of the anchor, or null when it is gone.
Rect? anchorRect(Element e) {
  if (!e.mounted) return null;
  final r = e.renderObject;
  if (r is! RenderBox || !r.attached || !r.hasSize) return null;
  return r.localToGlobal(Offset.zero) & r.size;
}

class AnchoredStep extends StatefulWidget {
  const AnchoredStep({
    super.key,
    required this.guide,
    required this.step,
    required this.buttons,
    required this.anchor,
    required this.target,
    required this.onAction,
  });
  final MobileGuide guide;
  final int step;
  final List<GuideButton> buttons;
  final GuideAnchor anchor;
  final Element target;
  final void Function(GuideButton?) onAction;

  @override
  State<AnchoredStep> createState() => _AnchoredStepState();
}

class _AnchoredStepState extends State<AnchoredStep> with SingleTickerProviderStateMixin {
  late final Timer _timer;
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 800), lowerBound: 1, upperBound: 1.35);
  final _bubbleKey = GlobalKey();
  Rect? _rect;
  DateTime? _goneSince;
  bool _open = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _open = !widget.anchor.hotspot;
    _rect = anchorRect(widget.target);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _follow());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.anchor.hotspot && !MediaQuery.of(context).disableAnimations && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  void _follow() {
    final r = anchorRect(widget.target);
    if (r == null) {
      _goneSince ??= DateTime.now();
      if (DateTime.now().difference(_goneSince!) > const Duration(seconds: 2)) _finish(null);
    } else {
      _goneSince = null;
    }
    if (mounted && r != _rect) setState(() => _rect = r);
  }

  void _finish(GuideButton? b) {
    if (_done) return;
    _done = true;
    widget.onAction(b);
  }

  @override
  void dispose() {
    _timer.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.guide;
    final s = g.steps[widget.step];
    final t = GuideTheme.tokens(g.appearance, systemDark: MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final scheme = Theme.of(context).colorScheme;
    final bg = guideColor(t.background) ?? scheme.surface;
    final fg = guideColor(t.text) ?? scheme.onSurface;
    final accent = guideColor(t.accent) ?? scheme.primary;
    final family = t.font?.split(',').first.trim().replaceAll(RegExp('["\']'), '');
    final r = _rect;
    final media = MediaQuery.of(context);
    final bounds = media.padding.deflateRect(Offset.zero & media.size);
    final width = (bounds.width - 24).clamp(120.0, 300.0).toDouble();
    final measured = _bubbleKey.currentContext?.size;
    if (measured == null && _open && r != null) {
      // first frame: place with an estimate, then again once the bubble's real height is known
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    final children = <Widget>[];
    if (r != null && widget.anchor.hotspot) {
      final c = Offset(r.right.clamp(bounds.left + 8, bounds.right - 8).toDouble(), r.top.clamp(bounds.top + 8, bounds.bottom - 8).toDouble());
      children.add(Positioned(
        left: c.dx - 8,
        top: c.dy - 8,
        child: Semantics(
          button: true,
          label: s.title ?? g.name,
          child: GestureDetector(
            onTap: () => setState(() => _open = true),
            child: ScaleTransition(
              scale: _pulse,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
              ),
            ),
          ),
        ),
      ));
    }
    if (r != null && _open) {
      final (x, y) = GuidePlacement.origin(width, measured?.height ?? 120, (r.left, r.top, r.width, r.height),
          (bounds.left, bounds.top, bounds.width, bounds.height), s.placement);
      final title = s.title ?? (widget.step == 0 ? g.name : null);
      children.add(Positioned(
        left: x,
        top: y,
        width: width,
        child: Material(
          key: _bubbleKey,
          color: bg,
          elevation: 6,
          borderRadius: BorderRadius.circular(t.radius ?? 10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: DefaultTextStyle(
              style: TextStyle(color: fg, fontSize: 15, fontFamily: family),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Semantics(header: true, child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
                  if (s.body != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(s.body!)),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    for (final b in widget.buttons)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: accent),
                        onPressed: () => _finish(b),
                        child: Text(b.label),
                      ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ));
    }
    return Stack(children: children); // empty areas hit-test nothing, so taps reach the app below
  }
}
