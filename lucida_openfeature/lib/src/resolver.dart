import 'package:lucida_core/lucida_core.dart';

/// Lucida reason -> OpenFeature reason; mirrors testdata/openfeature/reasons.json (the tests read that file).
const _reasons = {
  'condition_match': 'TARGETING_MATCH',
  'sticky_bucket': 'CACHED',
  'no_condition_match': 'DEFAULT',
  'out_of_rollout': 'DEFAULT',
  'holdout': 'DEFAULT',
  'namespace_excluded': 'DEFAULT',
  'no_bucketing_key': 'DEFAULT',
  'prerequisite_failed': 'DEFAULT',
  'prerequisite_missing': 'DEFAULT',
  'prerequisite_cycle': 'ERROR',
  'inactive': 'DISABLED',
  'kill_switch': 'DISABLED',
  'app_context_excluded': 'DISABLED',
  'preview': 'STATIC',
  'user_preview': 'STATIC',
  'fallback': 'DEFAULT',
};

/// `condition_match` resolving to a variant string is a SPLIT; unknown reasons are UNKNOWN.
String openFeatureReason(String lucidaReason, {required bool variantValue}) =>
    lucidaReason == 'condition_match' && variantValue ? 'SPLIT' : _reasons[lucidaReason] ?? 'UNKNOWN';

/// One resolved flag read. [errorCode] is `FLAG_NOT_FOUND` / `TYPE_MISMATCH` or null; a fallback has none.
class Resolution<T> {
  const Resolution(this.value, this.variant, this.reason, this.errorCode, this.errorMessage, this.metadata);
  final T value;
  final String? variant;
  final String reason;
  final String? errorCode;
  final String? errorMessage;

  /// `lucidaReason`, `conditionIndex` (when >= 0), `requestId` (when set), `evaluatedLocally`.
  final Map<String, Object> metadata;
}

Map<String, Object> flagMetadata(FlagDetails d) => {
      'lucidaReason': d.reason,
      'evaluatedLocally': d.evaluatedLocally,
      if (d.conditionIndex >= 0) 'conditionIndex': d.conditionIndex,
      if (d.requestId != null) 'requestId': d.requestId!,
    };

/// SDK-independent half of the provider: context -> identity, flag reads -> [Resolution], track -> capture.
class LucidaResolver {
  LucidaResolver(this.lucida);
  final Lucida lucida;

  /// `targetingKey` identifies; `groups` (type -> key) and `groupProperties` (type -> map) are reserved;
  /// every other attribute is a person property. Reloads flags once at the end.
  Future<void> setContext(Map<String, dynamic> ctx) async {
    final key = ctx['targetingKey'];
    final groups = (ctx['groups'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? <String, String>{};
    final gp = (ctx['groupProperties'] as Map?)?.map((k, v) => MapEntry('$k', Map<String, dynamic>.from(v as Map))) ??
        <String, Map<String, dynamic>>{};
    final person = Map<String, dynamic>.of(ctx)
      ..remove('targetingKey')
      ..remove('groups')
      ..remove('groupProperties');
    // core.* (not the facade) so identity changes do not start a second background reload.
    if (key is String && key.isNotEmpty && key != lucida.core.distinctId) lucida.core.identify(key);
    groups.forEach((t, k) => lucida.core.group(t, k, gp[t]));
    await lucida.flags.setPersonPropertiesForFlags(person, reload: false);
    for (final e in gp.entries) {
      if (!groups.containsKey(e.key)) await lucida.flags.setGroupPropertiesForFlags(e.key, e.value, reload: false);
    }
    await lucida.flags.reload();
  }

  Resolution<T> resolve<T>(String key, T def, T? Function(Object?) pick) {
    final d = lucida.flags.getFeatureFlagDetails(key);
    if (d == null) return Resolution(def, null, 'ERROR', 'FLAG_NOT_FOUND', 'flag $key not found', const {});
    final v = pick(d.value) ?? pick(d.payload);
    final meta = flagMetadata(d);
    if (v == null) return Resolution(def, null, 'ERROR', 'TYPE_MISMATCH', 'flag $key is not of the requested type', meta);
    return Resolution(v, d.variant, openFeatureReason(d.reason, variantValue: d.variant != null), null, null, meta);
  }

  /// Event = [name]; properties = [details] plus `$value`. The identity is the one set by the context.
  void track(String name, {Map<String, dynamic> details = const {}, num? value}) =>
      lucida.capture(name, {...details, if (value != null) '\$value': value});
}
