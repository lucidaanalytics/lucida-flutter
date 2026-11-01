import 'dart:convert';

/// The slice of `GET /v1/config` that governs replay (the document the browser SDK reads).
class RemoteReplayConfig {
  const RemoteReplayConfig({this.sessionRecording = true, this.sampleRate, this.minDurationMs});
  final bool sessionRecording;
  final double? sampleRate;
  final int? minDurationMs;

  static RemoteReplayConfig? parse(String json) {
    try {
      final o = jsonDecode(json);
      if (o is! Map) return null;
      return RemoteReplayConfig(
        sessionRecording: o['session_recording'] is bool ? o['session_recording'] as bool : true,
        sampleRate: (o['replay_sample_rate'] as num?)?.toDouble(),
        minDurationMs: (o['replay_min_duration_ms'] as num?)?.toInt(),
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
}
