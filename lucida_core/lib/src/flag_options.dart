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
      this.sendFeatureFlags = true});

  /// Emit `$feature_flag_called` when a flag is read.
  final bool sendFeatureFlagEvent;

  /// false: [Lucida.start] does not load flags; call `flags.reload()` when the app needs them.
  final bool preload;

  /// Attach `$feature/<key>` and `$active_feature_flags` to every event (never `$snapshot`); the caller's properties win.
  final bool sendFeatureFlags;

  /// Environment tags sent with the flag request; the server returns only flags whose tags match.
  final List<String> evaluationContexts;
}
