import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// Wrap the app to feed taps to [recorder] (replay touch overlay). Observes pointer-up only: it never cancels, delays or
/// consumes a touch, and records positions only, never what was typed. A no-op when `recorder.captureTouches` is false.
class LucidaTouchCapture extends StatelessWidget {
  const LucidaTouchCapture({super.key, required this.recorder, required this.child});
  final ReplayRecorder recorder;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerUp: (e) {
          if (recorder.captureTouches) recorder.tap(e.position.dx, e.position.dy);
        },
        child: child,
      );
}
