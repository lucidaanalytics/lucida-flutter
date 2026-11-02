/// Identity and flag values known before the first network response (server-rendered, or from a previous launch).
class Bootstrap {
  const Bootstrap({this.distinctId, this.isIdentified = false, this.flags = const {}, this.payloads = const {}});
  final String? distinctId;
  final bool isIdentified;
  final Map<String, dynamic> flags;
  final Map<String, dynamic> payloads;
}

class FlagOptions {
  const FlagOptions(
      {this.sendFeatureFlagEvent = true,
      this.preload = true,
      this.evaluationContexts = const [],
      this.sendFeatureFlags = true,
      this.fallbacks = const {}});

  /// Emit `$feature_flag_called` when a flag is read.
  final bool sendFeatureFlagEvent;

  /// false: [Lucida.start] does not load flags; call `flags.reload()` when the app needs them.
  final bool preload;

  /// Attach `$feature/<key>` and `$active_feature_flags` to every event (never `$snapshot`); the caller's properties win.
  final bool sendFeatureFlags;

  /// Environment tags sent with the flag request; the server returns only flags whose tags match.
  final List<String> evaluationContexts;

  /// `{flagKey: value}` served with reason `fallback` when a flag has no value (missing, failed load, cold start); no events.
  final Map<String, dynamic> fallbacks;
}

/// Why a flag read returned what it did; [reason] is the raw Lucida reason (`condition_match`, `kill_switch`, `fallback`, ...).
class FlagDetails {
  const FlagDetails(this.value, this.payload, this.variant, this.reason, this.conditionIndex, this.requestId, this.evaluatedLocally);
  final Object? value;
  final Object? payload;
  final String? variant;
  final String reason;

  /// -1 when no condition decided the result.
  final int conditionIndex;
  final String? requestId;
  final bool evaluatedLocally;
}

class FlagMeta {
  const FlagMeta(this.reason, this.conditionIndex, this.local);
  final String reason;
  final int conditionIndex;
  final bool local;
}

enum FlagsStatus { changed, stale, error }
