/// P-M46 `$dead_swipe`: a swipe of at least 48 logical px after which nothing on screen scrolled, paged or changed (the
/// structure fingerprint ~700 ms after the gesture equals the one at its start). Carries geometry only, never text.
library;

import 'dart:math' as math;

const deadSwipeMinDistance = 48.0;
const deadSwipeSettle = Duration(milliseconds: 700);
const deadSwipeCooldownMs = 2000;

/// Dominant axis of end - start; screen y grows downwards.
String swipeDirection(double dx, double dy) =>
    dx.abs() >= dy.abs() ? (dx < 0 ? 'left' : 'right') : (dy < 0 ? 'up' : 'down');

/// The `$dead_swipe` properties when the swipe was dead and the 2 s cooldown has passed, else null.
Map<String, dynamic>? deadSwipeDecision(
    {required String screen,
    required String startScreen,
    required String startFingerprint,
    required String endFingerprint,
    required double dx,
    required double dy,
    required int nowMs,
    int? lastAt}) {
  final distance = math.sqrt(dx * dx + dy * dy);
  if (distance < deadSwipeMinDistance || screen != startScreen || startFingerprint != endFingerprint) return null;
  if (lastAt != null && nowMs - lastAt < deadSwipeCooldownMs) return null;
  return {'\$screen_name': screen, '\$swipe_direction': swipeDirection(dx, dy), '\$swipe_distance': distance.round()};
}
