import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucida_core/lucida_core.dart';

import 'guide_anchor.dart';

/// Guide steps as an AlertDialog via `showDialog`. Text is plain `Text`, never markup.
/// Give it the app's `navigatorKey` (the dialog needs a Navigator below a MaterialApp).
/// [openUrl] opens an https link (wire url_launcher in the app); links are ignored without it.
/// Resolved theme tokens color the dialog; a carousel shows a dot pager. Anchored steps (tooltip, hotspot,
/// tour with native_id) point at the widget keyed `ValueKey<String>(native_id)` through the navigator overlay.
class DialogGuidePresenter implements AnchoredGuidePresenter {
  DialogGuidePresenter(this.navigatorKey, {this.openUrl});
  final GlobalKey<NavigatorState> navigatorKey;
  final void Function(Uri url)? openUrl;

  @override
  void present(MobileGuide guide, int step, List<GuideButton> buttons, void Function(GuideButton?) onAction) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return onAction(null);
    final s = guide.steps[step];
    var done = false;
    void finish(GuideButton? b) {
      if (done) return;
      done = true;
      onAction(b);
    }

    final t = GuideTheme.tokens(guide.appearance, systemDark: MediaQuery.platformBrightnessOf(ctx) == Brightness.dark);
    final fg = guideColor(t.text);
    final accent = guideColor(t.accent);
    final carousel = guide.kind == 'carousel';
    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: guideColor(t.background),
        shape: t.radius == null ? null : RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius!)),
        title: Text(s.title ?? guide.name, style: fg == null ? null : TextStyle(color: fg)),
        content: s.body == null && !carousel
            ? null
            : Column(mainAxisSize: MainAxisSize.min, children: [
                if (s.body != null) Text(s.body!, style: fg == null ? null : TextStyle(color: fg)),
                if (carousel)
                  Semantics(
                    label: 'Slide ${step + 1} of ${guide.steps.length}',
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (var i = 0; i < guide.steps.length; i++)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                                shape: BoxShape.circle, color: i == step ? (accent ?? Colors.black87) : Colors.black26),
                          ),
                      ]),
                    ),
                  ),
              ]),
        actions: [
          for (final b in buttons)
            TextButton(
              style: accent == null ? null : TextButton.styleFrom(foregroundColor: accent),
              onPressed: () {
                Navigator.of(c).pop();
                finish(b);
              },
              child: Text(b.label),
            ),
        ],
      ),
    ).then((_) => finish(null)); // barrier tap / back
  }

  @override
  void presentAnchored(MobileGuide guide, int step, List<GuideButton> buttons, GuideAnchor anchor,
      void Function() onMissing, void Function(GuideButton?) onAction) {
    final deadline = DateTime.now().add(Duration(milliseconds: anchor.waitMs));
    void attempt() {
      final overlay = navigatorKey.currentState?.overlay;
      if (overlay == null) return onAction(null);
      final target = findGuideAnchor(anchor.nativeId);
      if (target != null) {
        late final OverlayEntry entry;
        entry = OverlayEntry(
          builder: (_) => AnchoredStep(
            guide: guide,
            step: step,
            buttons: buttons,
            anchor: anchor,
            target: target,
            onAction: (b) {
              entry.remove();
              onAction(b);
            },
          ),
        );
        overlay.insert(entry);
      } else if (!DateTime.now().isBefore(deadline)) {
        onMissing();
        present(guide, step, buttons, onAction);
      } else {
        Timer(const Duration(milliseconds: 150), attempt);
      }
    }

    attempt();
  }

  @override
  void open(Uri url) => openUrl?.call(url);
}
