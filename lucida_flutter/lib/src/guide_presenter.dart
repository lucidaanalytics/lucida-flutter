import 'package:flutter/material.dart';
import 'package:lucida_core/lucida_core.dart';

/// Guide steps as an AlertDialog via `showDialog`. Text is plain `Text`, never markup.
/// Give it the app's `navigatorKey` (the dialog needs a Navigator below a MaterialApp).
/// [openUrl] opens an https link (wire url_launcher in the app); links are ignored without it.
class DialogGuidePresenter implements GuidePresenter {
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

    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(s.title ?? guide.name),
        content: s.body == null ? null : Text(s.body!),
        actions: [
          for (final b in buttons)
            TextButton(
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
  void open(Uri url) => openUrl?.call(url);
}
