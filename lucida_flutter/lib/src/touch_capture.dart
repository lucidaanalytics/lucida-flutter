import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// Wrap the app to feed taps to [recorder] (replay touch overlay) and swipes to its `$dead_swipe` check. Observes
/// pointers only: it never cancels, delays or consumes a touch, and records positions only, never what was typed.
/// Taps are a no-op when `recorder.captureTouches` is false, swipes when `recorder.captureDeadSwipes` is.
class LucidaTouchCapture extends StatefulWidget {
  const LucidaTouchCapture({super.key, required this.recorder, required this.child});
  final ReplayRecorder recorder;
  final Widget child;

  @override
  State<LucidaTouchCapture> createState() => _LucidaTouchCaptureState();
}

class _LucidaTouchCaptureState extends State<LucidaTouchCapture> {
  int? _pointer;
  Offset _down = Offset.zero;
  bool _swiping = false;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (_pointer != null) return; // first finger only
          _pointer = e.pointer;
          _down = e.position;
          _swiping = false;
        },
        // This listener runs in the same dispatch as the scrollables, before the next frame moves anything.
        onPointerMove: (e) {
          if (e.pointer != _pointer || _swiping || (e.position - _down).distance <= kTouchSlop) return;
          _swiping = true;
          widget.recorder.swipeBegan();
        },
        onPointerUp: (e) {
          final r = widget.recorder;
          if (r.captureTouches) r.tap(e.position.dx, e.position.dy);
          if (e.pointer != _pointer) return;
          _pointer = null;
          if (_swiping) r.swipeEnded(e.position.dx - _down.dx, e.position.dy - _down.dy);
        },
        onPointerCancel: (e) {
          if (e.pointer == _pointer) _pointer = null;
        },
        child: widget.child,
      );
}
