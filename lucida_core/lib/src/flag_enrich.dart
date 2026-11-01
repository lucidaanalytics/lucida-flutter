/// Event enrichment with flag values (LC-FLG-28): `$feature/<key>` per flag plus sorted `$active_feature_flags`
/// (keys whose value is not false). Empty when no flag is known.
Map<String, dynamic> flagEventProps(Map<String, dynamic> values) {
  if (values.isEmpty) return const {};
  final active = [
    for (final e in values.entries)
      if (e.value != false) e.key,
  ]..sort();
  return {
    for (final e in values.entries) '\$feature/${e.key}': e.value,
    '\$active_feature_flags': active,
  };
}
