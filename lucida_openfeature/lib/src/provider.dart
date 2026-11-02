import 'dart:async';

import 'package:lucida_core/lucida_core.dart';
import 'package:openfeature_dart_server_sdk/feature_provider.dart';

import 'resolver.dart';

enum LucidaProviderEvent { ready, configurationChanged, stale, error }

/// OpenFeature provider over the Lucida Dart SDK (static-context paradigm): [initializeContext] /
/// [onContextChange] identify the targeting key, apply attributes as person properties and reload flags;
/// reads are synchronous over the loaded flags. Written against openfeature_dart_server_sdk 0.0.15.
///
/// The pinned SDK has no flagMetadata or event channel, so [lastMetadata] and [events] expose them.
class LucidaFeatureProvider implements FeatureProvider {
  LucidaFeatureProvider(Lucida lucida) : _r = LucidaResolver(lucida) {
    lucida.flags.onFlagsStatus((s) => _events.add(switch (s) {
          FlagsStatus.changed => LucidaProviderEvent.configurationChanged,
          FlagsStatus.stale => LucidaProviderEvent.stale,
          FlagsStatus.error => LucidaProviderEvent.error,
        }));
  }

  final LucidaResolver _r;
  final _events = StreamController<LucidaProviderEvent>.broadcast();
  Map<String, Object> lastMetadata = const {};

  Stream<LucidaProviderEvent> get events => _events.stream;

  @override
  String get name => 'Lucida';

  Future<void> initializeContext(Map<String, dynamic> context) async {
    await _r.setContext(context);
    _events.add(LucidaProviderEvent.ready);
  }

  Future<void> onContextChange(Map<String, dynamic> context) => _r.setContext(context);

  /// OpenFeature tracking API: event name, evaluation context (identity already set), details + optional value.
  void track(String eventName, {Map<String, dynamic> details = const {}, num? value}) =>
      _r.track(eventName, details: details, value: value);

  FlagEvaluationResult<T> _out<T>(String key, Resolution<T> r) {
    lastMetadata = r.metadata;
    return FlagEvaluationResult<T>(key, r.value, DateTime.now(), name,
        variant: r.variant, reason: r.reason, errorMessage: r.errorMessage);
  }

  @override
  Future<FlagEvaluationResult<bool>> getBooleanFlag(String flagKey, bool defaultValue, {Map<String, dynamic>? context}) async =>
      _out(flagKey, _r.resolve<bool>(flagKey, defaultValue, (v) => v is bool ? v : null));

  @override
  Future<FlagEvaluationResult<String>> getStringFlag(String flagKey, String defaultValue, {Map<String, dynamic>? context}) async =>
      _out(flagKey, _r.resolve<String>(flagKey, defaultValue, (v) => v is String ? v : null));

  @override
  Future<FlagEvaluationResult<int>> getIntegerFlag(String flagKey, int defaultValue, {Map<String, dynamic>? context}) async =>
      _out(flagKey, _r.resolve<int>(flagKey, defaultValue, (v) => v is num ? v.toInt() : null));

  @override
  Future<FlagEvaluationResult<double>> getDoubleFlag(String flagKey, double defaultValue, {Map<String, dynamic>? context}) async =>
      _out(flagKey, _r.resolve<double>(flagKey, defaultValue, (v) => v is num ? v.toDouble() : null));

  @override
  Future<FlagEvaluationResult<Map<String, dynamic>>> getObjectFlag(String flagKey, Map<String, dynamic> defaultValue,
          {Map<String, dynamic>? context}) async =>
      _out(flagKey, _r.resolve<Map<String, dynamic>>(flagKey, defaultValue, (v) => v is Map ? Map<String, dynamic>.from(v) : null));
}
