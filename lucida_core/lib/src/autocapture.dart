import 'dart:math';

import 'core.dart';
import 'queue.dart';

class RageTapConfig {
  const RageTapConfig({this.enabled = true, this.minTaps = 3, this.windowMs = 1000, this.radius = 30.0});
  final bool enabled;
  final int minTaps;
  final int windowMs;
  final double radius;
}

/// Element autocapture (`$autocapture` taps and changes). Off by default.
/// Privacy: text-field values are never collected; [propsAllowList] is the only way extra element props leave the device.
class AutocaptureConfig {
  const AutocaptureConfig({
    this.enabled = false,
    this.ignoreLabels = const {},
    this.maxElements = 10,
    this.propsAllowList = const {},
    this.noCaptureMarker = 'lc-no-capture',
    this.rageTap = const RageTapConfig(),
  });
  final bool enabled;
  final Set<String> ignoreLabels;
  final int maxElements;
  final Set<String> propsAllowList;

  /// An element with this marker (and its subtree) is never captured.
  final String noCaptureMarker;
  final RageTapConfig rageTap;
}

/// One entry in the tapped element's ancestor chain (platform-neutral; adapters build it).
class TapElement {
  const TapElement(this.name, {this.label, this.tag, this.isInput = false, this.props = const {}});
  final String name;
  final String? label;
  final String? tag;
  final bool isInput;
  final Map<String, String> props;
}

class Autocapture {
  Autocapture(this._core, this.cfg);
  final Core _core;
  final AutocaptureConfig cfg;
  final List<({int t, double x, double y})> _taps = [];

  /// [chain] runs from the tapped element up to the root. Returns the `$autocapture` event, or null when skipped.
  WireEvent? tap(List<TapElement> chain, double x, double y) => _emit('touch', chain, x, y);

  WireEvent? change(List<TapElement> chain) => _emit('change', chain, null, null);

  WireEvent? _emit(String type, List<TapElement> chain, double? x, double? y) {
    if (!cfg.enabled || chain.any((e) => e.tag == cfg.noCaptureMarker)) return null;
    final kept = chain
        .where((e) => !cfg.ignoreLabels.contains(e.name) && !cfg.ignoreLabels.contains(e.label))
        .take(cfg.maxElements)
        .toList();
    if (kept.isEmpty) return null;
    final els = [
      for (final el in kept)
        <String, dynamic>{
          'tag_name': el.name,
          // Inputs never expose label text: it can echo what the user typed.
          if (!el.isInput && (el.label?.isNotEmpty ?? false))
            'text': el.label!.length > 255 ? el.label!.substring(0, 255) : el.label,
          for (final p in el.props.entries)
            if (cfg.propsAllowList.contains(p.key)) 'attr__${p.key}': p.value,
        }
    ];
    final r = _core.capture('\$autocapture', {
      '\$event_type': type,
      '\$elements': els,
      '\$el_text': els.map((e) => e['text']).firstWhere((t) => t != null, orElse: () => ''),
    });
    if (type == 'touch' && x != null && y != null) _rage(els.first, x, y);
    return r;
  }

  void _rage(Map<String, dynamic> top, double x, double y) {
    final rc = cfg.rageTap;
    if (!rc.enabled) return;
    final now = _core.now();
    _taps.add((t: now, x: x, y: y));
    _taps.removeWhere((t) => now - t.t > rc.windowMs);
    final near = _taps.where((t) => sqrt(pow(t.x - x, 2) + pow(t.y - y, 2)) <= rc.radius).length;
    if (near >= rc.minTaps) {
      _taps.clear();
      _core.capture('\$rageclick', {
        '\$event_type': 'touch',
        '\$tap_count': near,
        '\$elements': [top],
      });
    }
  }
}
