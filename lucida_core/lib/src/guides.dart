import 'dart:convert';
import 'dart:math';

import 'core.dart';
import 'flag_eval.dart' show Json;
import 'guide_rules.dart';

/// A guide as `GET /v1/guides` serves it (the same definitions the browser SDK renders).
class MobileGuide {
  MobileGuide(
    this.id,
    this.name,
    this.kind,
    this.steps,
    this.conditions, {
    this.preview = false,
    this.heldOut = false,
    this.appearance,
    this.queued = false,
  });
  final String id;
  final String name;
  final String kind;
  final List<GuideStep> steps;
  final Json conditions;

  /// A draft served to one of its QA users: no targeting, shown once per launch, no events.
  final bool preview;

  /// This person is in the guide's holdout (decided by the gateway): never shown, carries no steps.
  final bool heldOut;

  /// Resolved appearance (the gateway merges the project theme in): tokens, dark.tokens, theme_mode, font_family.
  final Json? appearance;

  /// A workflow queued this guide for this person (gateway): it goes first and skips sampling.
  final bool queued;

  factory MobileGuide.fromJson(Json o) => MobileGuide(
        o['id'] as String,
        o['name'] as String,
        o['kind'] as String,
        [for (final s in o['steps'] as List) GuideStep.fromJson(Map<String, dynamic>.from(s as Map))],
        o['conditions'] is Map ? Map<String, dynamic>.from(o['conditions'] as Map) : <String, dynamic>{},
        preview: o['preview'] == true,
        heldOut: o['held_out'] == true,
        appearance: o['appearance'] is Map ? Map<String, dynamic>.from(o['appearance'] as Map) : null,
        queued: o['queued'] == true,
      );
}

class GuideStep {
  GuideStep(this.id, this.title, this.body, this.buttons, {this.nativeId, this.placement, this.waitMs});
  final String id;
  final String? title;
  final String? body;
  final List<GuideButton>? buttons;

  /// Anchor widget: the `ValueKey<String>` it carries (tooltip, hotspot and tour steps; web selectors are ignored).
  final String? nativeId;

  /// top | bottom | left | right (mobile draws above or below).
  final String? placement;

  /// How long to wait for the anchor (ms, default 3000, max 15000) before showing the step unanchored.
  final int? waitMs;

  factory GuideStep.fromJson(Json o) => GuideStep(
        o['id'] as String,
        o['title'] as String?,
        o['body'] as String?,
        o['buttons'] == null
            ? null
            : [for (final b in o['buttons'] as List) GuideButton.fromJson(Map<String, dynamic>.from(b as Map))],
        nativeId: o['native_id'] as String?,
        placement: o['placement'] as String?,
        waitMs: (o['wait_ms'] as num?)?.toInt(),
      );
}

/// action: next | back | dismiss | link | event (start_tour behaves like next on mobile).
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

/// Where an anchored step points. [hotspot]: a pulsing dot on the widget opens the step when tapped.
class GuideAnchor {
  const GuideAnchor(this.nativeId, this.placement, this.waitMs, this.hotspot);
  final String nativeId;
  final String? placement;
  final int waitMs;
  final bool hotspot;

  @override
  bool operator ==(Object o) =>
      o is GuideAnchor &&
      o.nativeId == nativeId &&
      o.placement == placement &&
      o.waitMs == waitMs &&
      o.hotspot == hotspot;

  @override
  int get hashCode => Object.hash(nativeId, placement, waitMs, hotspot);
}

/// Optional port extension: a presenter that can point a step at a widget (adapter: `DialogGuidePresenter`). When
/// the widget does not appear within [GuideAnchor.waitMs] it calls `onMissing` and shows the step unanchored.
abstract class AnchoredGuidePresenter implements GuidePresenter {
  void presentAnchored(
    MobileGuide guide,
    int step,
    List<GuideButton> buttons,
    GuideAnchor anchor,
    void Function() onMissing,
    void Function(GuideButton?) onAction,
  );
}

/// Off by default: no `/v1/guides` request until the app opts in.
class GuidesConfig {
  GuidesConfig({this.enabled = false, this.presenter});
  bool enabled;
  GuidePresenter? presenter;
}

/// In-app guides on mobile (LC-ENG-15). Kinds modal, banner, announcement, slideout, carousel (Back / Next),
/// tour (steps in order), and tooltip / hotspot when the presenter anchors ([AnchoredGuidePresenter], N-DAP-10:
/// a step's native_id is the anchor widget's ValueKey; a missing one emits $guide_target_missing and the step
/// shows unanchored). Web step selectors are ignored. Targeting: url (screen name; url_match exact/contains/regex),
/// flag_key, sample_pct, devices (mobile or tablet), seen_guides / not_seen_guides, schedule (window
/// plus weekday / hour recurrence), frequency, and A/B ab_group / holdout_pct (G241: the gateway picks
/// the variant and holdout for this distinct id and decides recurrence in the offset sent as
/// `tz_offset`). A guide using any other targeting key is skipped. Without frequency a guide shows once
/// per device, a repeatable one at most once per screen visit; one at a time; preview guides are quiet
/// and once per launch. Shows are synced to the guide-state store so a cap counts every device.
/// Events: $guide_shown, $guide_step, $guide_completed, $guide_dismissed, $guide_holdout.
class GuidesService {
  GuidesService(this._core, this.config, this._flag, {double Function()? random, DateTime Function()? now})
      : _random = random ?? Random().nextDouble,
        _now = now ?? DateTime.now {
    final raw = _core.storage.get(_seenKey);
    if (raw != null) {
      try {
        _seen.addAll((jsonDecode(raw) as List).whereType<String>());
      } catch (_) {
        /* corrupt: start empty */
      }
    }
    try {
      _held.addAll((jsonDecode(_core.storage.get(GuideRules.heldKey) ?? '[]') as List).whereType<String>());
      (jsonDecode(_core.storage.get(GuideRules.viewsKey) ?? '{}') as Map).forEach((k, v) {
        _views[k as String] = [
          for (final t in v as List)
            if (t is num) t.toInt(),
        ];
      });
    } catch (_) {
      /* corrupt: start empty */
    }
  }

  static const _seenKey = 'lc_guide_seen';
  static const kinds = {'modal', 'banner', 'announcement', 'slideout', 'tour', 'carousel', 'tooltip', 'hotspot'};

  /// Kinds whose steps may point at a widget.
  static const anchorable = {'tooltip', 'hotspot', 'tour'};
  static const handled = {
    'url',
    'url_match',
    'flag_key',
    'sample_pct',
    'devices',
    'seen_guides',
    'not_seen_guides',
    'delay_seconds',
    'goal',
    'schedule',
    'frequency',
    'ab_group',
    'ab_weight',
    'holdout_pct',
    'holdout_scope',
    'exclude_url_patterns',
  };

  /// Project-wide exclusions matched against the screen name: `*` globs, the same patterns the web matches against URLs.
  static bool excluded(String screen, List<String> patterns) =>
      patterns.any((p) => p.isNotEmpty && RegExp('^${p.split('*').map(RegExp.escape).join('.*')}\$').hasMatch(screen));

  final Core _core;
  final GuidesConfig config;
  final bool Function(String) _flag;
  final double Function() _random;
  final DateTime Function() _now;
  final Map<String, List<int>> _views = {};
  final Set<String> _held = {};

  /// Guides shown since the app moved to the current screen (a repeatable guide shows once per visit).
  final Set<String> _shownHere = {};
  List<MobileGuide> _guides = [];
  final Set<String> _seen = {};
  final Set<String> _previewed = {};
  bool _showing = false;
  String? _screen;

  /// Fetches the project's live guides (needs analytics consent), then re-evaluates the current screen.
  Future<void> reload() async {
    if (!config.enabled || !_core.consent.has('analytics')) return;
    final q =
        'api_key=${Uri.encodeQueryComponent(_core.c.apiKey)}&distinct_id=${Uri.encodeQueryComponent(_core.distinctId)}'
        '&tz_offset=${_now().timeZoneOffset.inMinutes}';
    final r = await _core.c.http.send('GET', '${_core.c.apiHost.replaceAll(RegExp(r'/+$'), '')}/v1/guides?$q');
    if (r.status < 200 || r.status >= 300) return;
    final out = <MobileGuide>[];
    try {
      for (final g in (jsonDecode(r.body) as Map)['guides'] as List? ?? const []) {
        try {
          out.add(MobileGuide.fromJson(Map<String, dynamic>.from(g as Map)));
        } catch (_) {
          /* malformed guide: skip it */
        }
      }
    } catch (_) {
      return;
    }
    final fresh = out.where((g) => g.heldOut && _held.add(g.id)).toList();
    if (fresh.isNotEmpty) _core.storage.set(GuideRules.heldKey, jsonEncode(_held.toList()..sort()));
    for (final g in fresh) {
      final grp = g.conditions['ab_group'];
      _core.capture('\$guide_holdout', _props(g, grp is String && grp.isNotEmpty ? {'\$guide_group': grp} : const {}));
    }
    _guides = out;
    final at = _screen;
    if (at != null) show(at);
  }

  /// The app moved to [name]: show the first eligible guide, if none is on screen.
  void show(String name) {
    if (_screen != name) _shownHere.clear();
    _screen = name;
    if (_showing) return;
    MobileGuide? g;
    // workflow-queued guides go first
    for (final c in [..._guides.where((x) => x.queued), ..._guides.where((x) => !x.queued)]) {
      if (_eligible(c, name)) {
        g = c;
        break;
      }
    }
    if (g == null) return;
    final p = config.presenter;
    if (p == null) return;
    _showing = true;
    _shownHere.add(g.id);
    if (g.preview) {
      _previewed.add(g.id);
    } else {
      _markSeen(g.id);
      _recordView(g.id);
      _core.capture('\$guide_shown', _props(g));
    }
    _present(p, g, 0);
  }

  bool _eligible(MobileGuide g, String name) {
    if (!kinds.contains(g.kind) || g.steps.isEmpty) return false;
    // tooltip / hotspot exist only next to a widget: they need an anchor and a presenter that can draw one
    if ((g.kind == 'tooltip' || g.kind == 'hotspot') &&
        ((g.steps[0].nativeId ?? '').isEmpty || config.presenter is! AnchoredGuidePresenter)) {
      return false;
    }
    if (g.preview) return !_previewed.contains(g.id);
    final c = g.conditions;
    // null, "" and [] are the editor's "not set"
    bool unset(Object? v) => v == null || v == '' || (v is List && v.isEmpty);
    final used = c.entries.where((e) => !unset(e.value)).map((e) => e.key);
    if (g.heldOut || _shownHere.contains(g.id) || !used.every(handled.contains)) return false;
    final freq = c['frequency'];
    if (freq is Map) {
      if (!GuideRules.frequencyOk(freq, _views[g.id] ?? const [], _now())) return false;
    } else if (_seen.contains(g.id)) {
      return false;
    }
    if (!GuideRules.scheduleOk(c['schedule'], _now())) return false;
    final url = c['url'];
    if (url is String && url.isNotEmpty && !matches(name, url, c['url_match'] as String? ?? 'contains')) return false;
    final fk = c['flag_key'];
    if (fk is String && fk.isNotEmpty && !_flag(fk)) return false;
    final pats = c['exclude_url_patterns'];
    if (pats is List && excluded(name, pats.whereType<String>().toList())) return false;
    final pct = c['sample_pct'];
    if (!g.queued && pct is num && _random() * 100 >= pct) return false;
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
    if (g.kind == 'carousel') {
      final last = i == g.steps.length - 1;
      return [
        if (i > 0) const GuideButton('Back', 'back'),
        GuideButton(last ? 'Done' : 'Next', 'next'),
        const GuideButton('Dismiss', 'dismiss'),
      ];
    }
    return [GuideButton(i == g.steps.length - 1 ? 'Done' : 'Next', 'next'), const GuideButton('Dismiss', 'dismiss')];
  }

  /// The anchor of step [i], when its guide kind anchors and the step names a widget.
  static GuideAnchor? anchor(MobileGuide g, int i) {
    final s = g.steps[i];
    final id = s.nativeId;
    if (!anchorable.contains(g.kind) || id == null || id.isEmpty) return null;
    return GuideAnchor(id, s.placement, (s.waitMs ?? 3000).clamp(0, 15000).toInt(), g.kind == 'hotspot');
  }

  void _present(GuidePresenter p, MobileGuide g, int i) {
    final a = anchor(g, i);
    if (a != null && p is AnchoredGuidePresenter) {
      final step = g.steps[i].id;
      return p.presentAnchored(g, i, buttons(g, i), a, () {
        if (g.preview) return;
        _core.capture(
          '\$guide_target_missing',
          _props(g, {'guide_id': g.id, 'step_id': step, '\$guide_step_id': step, 'selector': a.nativeId}),
        );
      }, (b) => _handle(p, g, i, b));
    }
    p.present(g, i, buttons(g, i), (b) => _handle(p, g, i, b));
  }

  void _handle(GuidePresenter p, MobileGuide g, int i, GuideButton? b) {
    final quiet = g.preview;
    final step = <String, dynamic>{'\$guide_step_id': g.steps[i].id, '\$guide_step_index': i};
    if (b == null || b.action == 'dismiss') {
      if (!quiet) _core.capture('\$guide_dismissed', _props(g, step));
      return _finish();
    }
    if (b.action == 'back') return _present(p, g, i > 0 ? i - 1 : 0);
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

  void _recordView(String id) {
    final v = [...?_views[id], _now().millisecondsSinceEpoch];
    _views[id] = v.length > GuideRules.maxViews ? v.sublist(v.length - GuideRules.maxViews) : v;
    _core.storage.set(GuideRules.viewsKey, jsonEncode(_views));
    syncViews(Map.of(_views)).ignore();
  }

  /// Read-modify-write of the person's guide state (`POST /v1/guide-state`, analytics consent only):
  /// this device's views are merged in and every other key the browser SDK wrote is kept.
  Future<void> syncViews(Map<String, List<int>> local) async {
    if (!_core.consent.has('analytics')) return;
    final url = '${_core.c.apiHost.replaceAll(RegExp(r'/+$'), '')}/v1/guide-state';
    final base = <String, dynamic>{'api_key': _core.c.apiKey, 'distinct_id': _core.distinctId};
    const headers = {'Content-Type': 'application/json'};
    try {
      final r = await _core.c.http.send('POST', url, body: jsonEncode(base), headers: headers);
      if (r.status < 200 || r.status >= 300) return;
      final state = ((jsonDecode(r.body) as Map)['state'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      await _core.c.http.send(
        'POST',
        url,
        body: jsonEncode({...base, 'state': GuideRules.merged(state, local)}),
        headers: headers,
      );
    } catch (_) {
      /* offline: the next show retries */
    }
  }

  Map<String, dynamic> _props(MobileGuide g, [Map<String, dynamic> extra = const {}]) => {
        ...extra,
        '\$guide_id': g.id,
        '\$guide_kind': g.kind,
      };
}
