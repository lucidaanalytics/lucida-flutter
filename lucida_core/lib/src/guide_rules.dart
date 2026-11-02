import 'flag_eval.dart' show Json;

/// The schedule, frequency and holdout rules on mobile (G241). The gateway already decides them for
/// this person (recurrence in the offset sent as `tz_offset`, frequency from the views synced to the
/// guide-state store, A/B variant and holdout from the distinct id); these local checks keep a guide
/// fetched earlier from showing after its hours or over its cap on this device.
class GuideRules {
  static const viewsKey = 'lc_guide_views';
  static const heldKey = 'lc_guide_held';

  /// Views kept per guide (the browser SDK keeps the newest 50 too).
  static const maxViews = 50;

  /// Inside `schedule`: the RFC 3339 window, then weekdays (0 = Sunday) and hours [from, to) in
  /// device time. A guide pinned to a `timezone` had its recurrence decided by the gateway (Dart has
  /// no zone database), so only its window is checked here.
  static bool scheduleOk(Object? schedule, DateTime now) {
    if (schedule is! Map) return true;
    final start = DateTime.tryParse(schedule['start'] as String? ?? '');
    if (start != null && now.isBefore(start)) return false;
    final end = DateTime.tryParse(schedule['end'] as String? ?? '');
    if (end != null && !now.isBefore(end)) return false;
    final tz = schedule['timezone'];
    if (tz is String && tz.isNotEmpty) return true;
    final local = now.toLocal();
    final days = schedule['days'];
    if (days is List && days.isNotEmpty && !days.any((d) => d is num && d.toInt() == local.weekday % 7)) return false;
    final h = schedule['hours'];
    if (h is! Map) return true;
    final from = (h['from'] as num?)?.toInt() ?? 0;
    final to = (h['to'] as num?)?.toInt() ?? 24;
    return local.hour >= from && local.hour < to;
  }

  /// Under `frequency` (`max_views` per rolling `per_days`, lifetime when omitted).
  static bool frequencyOk(Map frequency, List<int> views, DateTime now) {
    final ms = now.millisecondsSinceEpoch;
    final perDays = frequency['per_days'];
    final since = perDays is num ? ms - (perDays * 86400000).round() : 0;
    final max = (frequency['max_views'] as num?)?.toInt() ?? 1;
    return views.where((t) => t >= since).length < max;
  }

  /// Merges this device's views into the stored guide state, keeping every other key.
  static Json merged(Json state, Map<String, List<int>> views) {
    final stored = <String, dynamic>{...?(state[viewsKey] as Map?)?.cast<String, dynamic>()};
    views.forEach((id, v) {
      final old = [for (final t in (stored[id] as List?) ?? const []) if (t is num) t.toInt()];
      final all = {...old, ...v}.toList()..sort();
      stored[id] = all.length > maxViews ? all.sublist(all.length - maxViews) : all;
    });
    return {...state, viewsKey: stored};
  }
}
