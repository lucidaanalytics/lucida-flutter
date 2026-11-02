import 'flag_eval.dart' show Json;

/// Resolved guide colors (#hex), corner radius (0..32) and font family.
class GuideTokens {
  const GuideTokens({this.background, this.text, this.accent, this.radius, this.font});
  final String? background;
  final String? text;
  final String? accent;
  final double? radius;
  final String? font;

  /// `#rgb` / `#rrggbb` as an opaque ARGB int, null for anything else.
  static int? argb(String? hex) {
    if (hex == null || !_hex.hasMatch(hex)) return null;
    var h = hex.substring(1);
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    return 0xFF000000 | int.parse(h, radix: 16);
  }
}

final _hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$');

/// Guide appearance on mobile (N-DAP-9, P-M41): the gateway resolves the project theme into `appearance`, so
/// this only picks light or dark tokens (dark when theme_mode is dark, or auto and the platform is dark) and
/// re-checks values like the browser SDK.
class GuideTheme {
  static bool wantsDark(Json? a, {required bool systemDark}) {
    final dark = a?['dark'];
    if (dark is! Map || dark['tokens'] is! Map) return false;
    final mode = a?['theme_mode'] as String? ?? 'auto';
    return mode == 'dark' || (mode == 'auto' && systemDark);
  }

  static GuideTokens tokens(Json? a, {required bool systemDark}) {
    String? background, text, accent;
    double? radius;
    String? font = a?['font_family'] as String?;
    final layers = <Map>[
      if (a?['tokens'] is Map) a!['tokens'] as Map,
      if (wantsDark(a, systemDark: systemDark)) (a!['dark'] as Map)['tokens'] as Map,
    ];
    String? color(Map l, String k) {
      final v = l[k];
      return v is String && _hex.hasMatch(v) ? v : null;
    }

    for (final l in layers) {
      background = color(l, 'background') ?? background;
      text = color(l, 'text') ?? text;
      accent = color(l, 'accent') ?? accent;
      final r = l['radius'];
      if (r is num && r >= 0 && r <= 32) radius = r.toDouble();
      final f = l['font'];
      if (f is String && f.trim().isNotEmpty) font = f;
    }
    return GuideTokens(background: background, text: text, accent: accent, radius: radius, font: font);
  }
}

/// Where an anchored bubble goes (N-DAP-10), in logical pixels; pure so it is unit-tested without Flutter.
class GuidePlacement {
  /// Below the target when it fits (or placement is not "top"), else above; centred and clamped to [margin].
  static (double, double) origin(
    double w,
    double h,
    (double, double, double, double) target,
    (double, double, double, double) bounds,
    String? placement, {
    double margin = 12,
    double gap = 8,
  }) {
    final (tl, tt, tw, th) = target;
    final (bl, bt, bw, bh) = bounds;
    final x = tl + tw / 2 - w / 2;
    final below = tt + th + gap;
    final above = tt - gap - h;
    final fitsBelow = below + h <= bt + bh - margin;
    final fitsAbove = above >= bt + margin;
    final y =
        placement == 'top' ? (fitsAbove || !fitsBelow ? above : below) : (fitsBelow || !fitsAbove ? below : above);
    double clamp(double v, double lo, double hi) => v < lo ? lo : (v > (hi < lo ? lo : hi) ? (hi < lo ? lo : hi) : v);
    return (clamp(x, bl + margin, bl + bw - margin - w), clamp(y, bt + margin, bt + bh - margin - h));
  }
}
