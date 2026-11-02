/// Privacy passes applied to a walked snapshot before it is encoded or turned into a screenshot mask plan: P-M17 masked
/// screens (unmask markers stop counting; the recorder forces every mask switch on) and P-M46 text patterns. Remote
/// config adds to the local lists, so it can only tighten.
library;

import 'wireframe.dart';

final _space = RegExp(r'\s');

/// Patterns that fail to compile are dropped, never fatal. No built-in patterns: the server masks emails/cards/phones again.
List<RegExp> compilePatterns(List<String> patterns) {
  final out = <RegExp>[];
  final seen = <String>{};
  for (final p in patterns) {
    if (p.isEmpty || !seen.add(p)) continue;
    try {
      out.add(RegExp(p));
    } catch (_) {}
  }
  return out;
}

/// Every character inside a match of any pattern becomes `*` (whitespace kept), like [maskText].
String maskPatterns(String text, List<RegExp> patterns) {
  if (patterns.isEmpty || text.isEmpty) return text;
  final hit = List<bool>.filled(text.length, false);
  var any = false;
  for (final re in patterns) {
    for (final m in re.allMatches(text)) {
      for (var i = m.start; i < m.end; i++) {
        hit[i] = true;
        any = true;
      }
    }
  }
  if (!any) return text;
  final b = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    b.write(hit[i] && !_space.hasMatch(c) ? '*' : c);
  }
  return b.toString();
}

bool matchesPatterns(String text, List<RegExp> patterns) => patterns.any((p) => p.hasMatch(text));

/// [maskScreen] clears every unmask marker. Patterns star matches in wireframe text (masked text is starred anyway, so
/// applying them to all text is equivalent); with [screenshot] a matching node becomes sensitive, so its pixels are
/// painted over last, after unmask regions are restored.
WireSnapshot applyPrivacy(WireSnapshot s,
    {required bool maskScreen, required List<RegExp> patterns, required bool screenshot}) {
  if (!maskScreen && patterns.isEmpty) return s;
  WireNode walk(WireNode n) {
    var text = n.text;
    var sensitive = n.sensitive;
    if (text != null && text.isNotEmpty && patterns.isNotEmpty) {
      if (!screenshot) {
        text = maskPatterns(text, patterns);
      } else if (matchesPatterns(text, patterns)) {
        sensitive = true;
        text = null;
      }
    }
    return WireNode(n.kind, n.x, n.y, n.width, n.height,
        text: text,
        background: n.background,
        sensitive: sensitive,
        unmask: !maskScreen && n.unmask,
        children: [for (final c in n.children) walk(c)]);
  }

  return WireSnapshot(s.screen, s.width, s.height, walk(s.root));
}
