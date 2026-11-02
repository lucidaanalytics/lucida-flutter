import 'dart:convert';

/// The project's RSA public key for controlled exposure (P-L12): [n] / [e] base64url without padding, [pkcs1] standard
/// base64 of the PKCS#1 RSAPublicKey DER.
class ExposureKey {
  const ExposureKey(this.kid, this.n, this.e, this.pkcs1);
  final String kid, n, e, pkcs1;
}

/// The slice of `GET /v1/config` that governs replay (the document the browser SDK reads). [maskScreens] (P-M17) and
/// [maskTextPatterns] (P-M46, at most 20, each <= 200 chars) add masking; [exposureFields] + [exposureKey] turn on
/// controlled exposure (P-L12) only when both are present.
class RemoteReplayConfig {
  const RemoteReplayConfig(
      {this.sessionRecording = true,
      this.sampleRate,
      this.minDurationMs,
      this.maskScreens = const [],
      this.maskTextPatterns = const [],
      this.exposureFields = const [],
      this.exposureKey});
  final bool sessionRecording;
  final double? sampleRate;
  final int? minDurationMs;
  final List<String> maskScreens;
  final List<String> maskTextPatterns;
  final List<String> exposureFields;
  final ExposureKey? exposureKey;

  static RemoteReplayConfig? parse(String json) {
    try {
      final o = jsonDecode(json);
      if (o is! Map) return null;
      List<String> strings(String k) => o[k] is List ? (o[k] as List).whereType<String>().toList() : const [];
      final k = o['replay_exposure_key'];
      ExposureKey? key;
      if (k is Map && k['kid'] is String && k['n'] is String && k['e'] is String && k['pkcs1'] is String) {
        key = ExposureKey(k['kid'] as String, k['n'] as String, k['e'] as String, k['pkcs1'] as String);
      }
      return RemoteReplayConfig(
        sessionRecording: o['session_recording'] is bool ? o['session_recording'] as bool : true,
        sampleRate: (o['replay_sample_rate'] as num?)?.toDouble(),
        minDurationMs: (o['replay_min_duration_ms'] as num?)?.toInt(),
        maskScreens: strings('replay_mask_screens'),
        maskTextPatterns: strings('replay_mask_text_patterns').where((p) => p.length <= 200).take(20).toList(),
        exposureFields: strings('replay_exposure_fields'),
        exposureKey: key,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Pure replay gating rules. Remote config can only tighten what the app configured locally.
class ReplayPolicy {
  const ReplayPolicy._();

  /// Deny wins; an empty allow list allows every screen.
  static bool screenAllowed(String screen, List<String> allow, List<String> deny) =>
      !deny.contains(screen) && (allow.isEmpty || allow.contains(screen));

  static double sampleRate(double local, RemoteReplayConfig? remote) {
    if (remote == null) return local;
    if (!remote.sessionRecording) return 0;
    final r = remote.sampleRate ?? 1;
    return local < r ? local : r;
  }

  static int minDurationMs(int local, RemoteReplayConfig? remote) {
    final r = remote?.minDurationMs ?? 0;
    return local > r ? local : r;
  }

  /// P-M17: case-insensitive match of the whole screen name; `*` matches any run of characters. Empty list = false.
  static bool screenMasked(String screen, List<String> patterns) {
    final s = screen.toLowerCase();
    return patterns.any((p) => _glob(s, p.toLowerCase()));
  }

  static bool _glob(String s, String p) {
    var si = 0, pi = 0, star = -1, mark = 0;
    while (si < s.length) {
      if (pi < p.length && p[pi] == '*') {
        star = pi;
        mark = si;
        pi++;
      } else if (pi < p.length && p[pi] == s[si]) {
        si++;
        pi++;
      } else if (star >= 0) {
        pi = star + 1;
        mark++;
        si = mark;
      } else {
        return false;
      }
    }
    while (pi < p.length && p[pi] == '*') {
      pi++;
    }
    return pi == p.length;
  }
}
