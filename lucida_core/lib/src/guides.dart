import 'dart:convert';
import 'dart:math';

import 'core.dart';
import 'flag_eval.dart' show Json;

/// A guide as `GET /v1/guides` serves it (the same definitions the browser SDK renders).
class MobileGuide {
  MobileGuide(this.id, this.name, this.kind, this.steps, this.conditions, {this.preview = false});
  final String id;
  final String name;
  final String kind;
  final List<GuideStep> steps;
  final Json conditions;

  /// A draft served to one of its QA users: no targeting, shown once per launch, no events.
  final bool preview;

  factory MobileGuide.fromJson(Json o) => MobileGuide(
        o['id'] as String,
        o['name'] as String,
        o['kind'] as String,
        [for (final s in o['steps'] as List) GuideStep.fromJson(Map<String, dynamic>.from(s as Map))],
        o['conditions'] is Map ? Map<String, dynamic>.from(o['conditions'] as Map) : <String, dynamic>{},
        preview: o['preview'] == true,
      );
}

class GuideStep {
  GuideStep(this.id, this.title, this.body, this.buttons);
  final String id;
  final String? title;
  final String? body;
  final List<GuideButton>? buttons;

  factory GuideStep.fromJson(Json o) => GuideStep(
        o['id'] as String,
        o['title'] as String?,
        o['body'] as String?,
        o['buttons'] == null
            ? null
            : [for (final b in o['buttons'] as List) GuideButton.fromJson(Map<String, dynamic>.from(b as Map))],
      );
}

/// action: next | dismiss | link | event (start_tour behaves like next on mobile).
class GuideButton {
  const GuideButton(this.label, this.action, {this.url, this.event});
  final String label;
  final String action;
  final String? url;
  final String? event;

  factory GuideButton.fromJson(Json o) =>
      GuideButton(o['label'] as String, o['action'] as String, url: o['url'] as String?, event: o['event'] as String?);
}

/// Port: draws one guide step natively. [onAction] gets the tapped button, or null when the person
/// closed the step without one (counts as a dismissal). Adapter: `DialogGuidePresenter` (lucida_flutter).
abstract class GuidePresenter {
  void present(MobileGuide guide, int step, List<GuideButton> buttons, void Function(GuideButton?) onAction);
  void open(Uri url);
}

/// Off by default: no `/v1/guides` request until the app opts in.
class GuidesConfig {
  GuidesConfig({this.enabled = false, this.presenter});
  bool enabled;
  GuidePresenter? presenter;
}

/// In-app guides on mobile (LC-ENG-15). Kinds modal, banner, announcement, slideout, tour (steps in
/// order); step selectors are ignored. Targeting: url (screen name; url_match exact/contains/regex),
/// flag_key, sample_pct, devices (mobile or tablet), seen_guides / not_seen_guides. A guide using any
/// other targeting key is skipped. Each guide shows once per device; one at a time; preview guides are
/// quiet and once per launch. Events: $guide_shown, $guide_step, $guide_completed, $guide_dismissed.
class GuidesService {
  GuidesService(this._core, this.config, this._flag, {double Function()? random})
      : _random = random ?? Random().nextDouble {
    final raw = _core.storage.get(_seenKey);
    if (raw != null) {
      try {
        _seen.addAll((jsonDecode(raw) as List).whereType<String>());
      } catch (_) {/* corrupt: start empty */}
    }
  }

  static const _seenKey = 'lc_guide_seen';
  static const kinds = {'modal', 'banner', 'announcement', 'slideout', 'tour'};
  static const handled = {
    'url', 'url_match', 'flag_key', 'sample_pct', 'devices', 'seen_guides', 'not_seen_guides', 'delay_seconds', 'goal'
  };

  final Core _core;
  final GuidesConfig config;
  final bool Function(String) _flag;
  final double Function() _random;
  List<MobileGuide> _guides = [];
  final Set<String> _seen = {};
  final Set<String> _previewed = {};
  bool _showing = false;
  String? _screen;

  /// Fetches the project's live guides (needs analytics consent), then re-evaluates the current screen.
  Future<void> reload() async {
    if (!config.enabled || !_core.consent.has('analytics')) return;
    final q = 'api_key=${Uri.encodeQueryComponent(_core.c.apiKey)}&distinct_id=${Uri.encodeQueryComponent(_core.distinctId)}';
    final r = await _core.c.http.send('GET', '${_core.c.apiHost.replaceAll(RegExp(r'/+$'), '')}/v1/guides?$q');
    if (r.status < 200 || r.status >= 300) return;
    final out = <MobileGuide>[];
    try {
      for (final g in (jsonDecode(r.body) as Map)['guides'] as List? ?? const []) {
        try {
          out.add(MobileGuide.fromJson(Map<String, dynamic>.from(g as Map)));
        } catch (_) {/* malformed guide: skip it */}
      }
    } catch (_) {
      return;
    }
    _guides = out;
    final at = _screen;
    if (at != null) show(at);
  }

  /// The app moved to [name]: show the first eligible guide, if none is on screen.
  void show(String name) {
    _screen = name;
    if (_showing) return;
    MobileGuide? g;
    for (final c in _guides) {
      if (_eligible(c, name)) {
        g = c;
        break;
      }
    }
    if (g == null) return;
    final p = config.presenter;
    if (p == null) return;
    _showing = true;
    if (g.preview) {
      _previewed.add(g.id);
    } else {
      _markSeen(g.id);
      _core.capture('\$guide_shown', _props(g));
    }
    _present(p, g, 0);
  }

  bool _eligible(MobileGuide g, String name) {
    if (!kinds.contains(g.kind) || g.steps.isEmpty) return false;
    if (g.preview) return !_previewed.contains(g.id);
    final c = g.conditions;
    // null, "" and [] are the editor's "not set"
    bool unset(Object? v) => v == null || v == '' || (v is List && v.isEmpty);
    final used = c.entries.where((e) => !unset(e.value)).map((e) => e.key);
    if (_seen.contains(g.id) || !used.every(handled.contains)) return false;
    final url = c['url'];
    if (url is String && url.isNotEmpty && !matches(name, url, c['url_match'] as String? ?? 'contains')) return false;
    final fk = c['flag_key'];
    if (fk is String && fk.isNotEmpty && !_flag(fk)) return false;
    final pct = c['sample_pct'];
    if (pct is num && _random() * 100 >= pct) return false;
    final devices = c['devices'];
    if (devices is List && devices.isNotEmpty && !devices.any((d) => d == 'mobile' || d == 'tablet')) return false;
    final need = c['seen_guides'];
    if (need is List && !need.every((i) => _seen.contains(i is String ? i : ''))) return false;
    final not = c['not_seen_guides'];
    if (not is List && not.any((i) => _seen.contains(i is String ? i : ''))) return false;
    return true;
  }

  static bool matches(String screen, String pattern, String how) {
    switch (how) {
      case 'exact':
        return screen == pattern;
      case 'regex':
        try {
          return RegExp(pattern).hasMatch(screen);
        } catch (_) {
          return false;
        }
      default:
        return screen.contains(pattern);
    }
  }

  static List<GuideButton> buttons(MobileGuide g, int i) {
    final b = g.steps[i].buttons;
    if (b != null && b.isNotEmpty) return b;
    if (g.kind == 'banner' || g.kind == 'announcement') return const [GuideButton('Dismiss', 'dismiss')];
    return [GuideButton(i == g.steps.length - 1 ? 'Done' : 'Next', 'next'), const GuideButton('Dismiss', 'dismiss')];
  }

  void _present(GuidePresenter p, MobileGuide g, int i) => p.present(g, i, buttons(g, i), (b) => _handle(p, g, i, b));

  void _handle(GuidePresenter p, MobileGuide g, int i, GuideButton? b) {
    final quiet = g.preview;
    final step = <String, dynamic>{'\$guide_step_id': g.steps[i].id, '\$guide_step_index': i};
    if (b == null || b.action == 'dismiss') {
      if (!quiet) _core.capture('\$guide_dismissed', _props(g, step));
      return _finish();
    }
    if (b.action == 'link') {
      final u = Uri.tryParse(b.url ?? '');
      if (u != null && u.scheme == 'https') p.open(u);
    }
    final ev = b.event;
    if (b.action == 'event' && !quiet && ev != null && ev.isNotEmpty) _core.capture(ev, {'\$guide_id': g.id});
    if (!quiet) _core.capture('\$guide_step', _props(g, step));
    if (i + 1 < g.steps.length && b.action != 'link') return _present(p, g, i + 1);
    if (!quiet) _core.capture('\$guide_completed', _props(g));
    _finish();
  }

  void _finish() {
    _showing = false;
    final at = _screen;
    if (at != null) show(at); // the next eligible guide, if any
  }

  void _markSeen(String id) {
    _seen.add(id);
    _core.storage.set(_seenKey, jsonEncode(_seen.toList()..sort()));
  }

  Map<String, dynamic> _props(MobileGuide g, [Map<String, dynamic> extra = const {}]) =>
      {...extra, '\$guide_id': g.id, '\$guide_kind': g.kind};
}
