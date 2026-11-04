import 'autocapture.dart';
import 'core.dart';
import 'flag_eval.dart';
import 'flag_options.dart';
import 'flags.dart';
import 'guides.dart';
import 'lifecycle.dart';
import 'replay.dart';
import 'host_headers.dart';
import 'install_attribution.dart';

/// Facade: one object a host app holds. Wires core + flags + lifecycle.
class Lucida {
  Lucida(CoreConfig config,
      {required String appVersion,
      String? appBuild,
      List<Json> flagDefinitions = const [],
      Map<String, dynamic> deviceProperties = const {},
      GuidesConfig? guides,
      this.flagOptions = const FlagOptions(),
      AutocaptureConfig autocaptureConfig = const AutocaptureConfig(),
      InstallSource? installSource})
      : core = Core(config) {
    flags = Flags(core,
        definitions: flagDefinitions, deviceProperties: deviceProperties, appVersion: appVersion, options: flagOptions);
    autocapture = Autocapture(core, autocaptureConfig);
    lifecycle = Lifecycle(core, version: appVersion, build: appBuild, installSource: installSource);
    this.guides = GuidesService(core, guides ?? GuidesConfig(), (k) => flags.isEnabled(k));
  }

  final Core core;
  final FlagOptions flagOptions;
  late final Autocapture autocapture;
  late final Flags flags;
  late final Lifecycle lifecycle;
  late final GuidesService guides;

  /// The replay recorder built for this client (`ReplayRecorder(lucida.core, ...)`); [captureSensitive] goes through it.
  ReplayRecorder? replay;

  /// Controlled exposure (P-L12): sends [value] RSA-encrypted with the project key as `$sensitive_capture`, only when
  /// [field] is listed in the project's exposure fields, the key is present, analytics + replay consent is held and
  /// [replay] is set. Only an audited reveal on the server can read it; identical values are sent once per session.
  bool captureSensitive(String field, String value) => replay?.captureSensitive(field, value) ?? false;

  /// Emit launch lifecycle events and load flags.
  Future<void> start() async {
    lifecycle.launched();
    await _reloadAll();
  }

  // Guides after flags: `flag_key` targeting reads them.
  Future<void> _reloadAll() async {
    if (flagOptions.preload) await flags.reload();
    await guides.reload();
  }

  void capture(String event,
          [Map<String, dynamic> props = const {}, Map<String, dynamic>? set, Map<String, dynamic>? setOnce]) =>
      core.capture(event, props, set, setOnce);
  void screen(String name, [Map<String, dynamic> props = const {}]) {
    guides.show(name);
    core.screen(name, props);
  }

  void identify(String id, [Map<String, dynamic>? set, Map<String, dynamic>? setOnce]) {
    core.identify(id, set, setOnce);
    _reloadAll();
  }

  void alias(String alias) => core.alias(alias);
  void setPersonProperties([Map<String, dynamic>? set, Map<String, dynamic>? setOnce]) =>
      core.setPersonProperties(set, setOnce);
  void register(Map<String, dynamic> props) => core.register(props);
  void registerOnce(Map<String, dynamic> props) => core.registerOnce(props);
  void unregister(String key) => core.unregister(key);
  void setConsent(Map<String, bool> update) => core.setConsent(update);
  bool get isOptedOut => core.isOptedOut;
  String get anonymousId => core.anonymousId;
  String get distinctId => core.distinctId;

  /// Current session id; reading it extends the idle window, like iOS `sessionId`.
  String get sessionId => core.session.touch();

  /// Runtime debug toggle.
  void debug(bool on) => core.debug = on;

  /// Record `$deep_link_opened`; call it from your router / platform link handler.
  void deepLink(String url, [String? referrer]) => core.deepLink(url, referrer);

  /// Header helper for your own backend calls; see [TracingHeaders].
  TracingHeaders get tracing => core.tracing;
  void group(String type, String key, [Map<String, dynamic>? props]) => core.group(type, key, props);
  void reset() {
    replay?.clearSpool();
    core.reset();
    _reloadAll();
  }

  void optIn() {
    core.optIn();
    _reloadAll();
  }

  void optOut() {
    replay?.clearSpool();
    core.optOut();
  }
  Future<void> flush() => core.flush();
}
