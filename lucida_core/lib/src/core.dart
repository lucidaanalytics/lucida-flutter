import 'consent.dart';
import 'encrypted_store.dart';
import 'flag_options.dart';
import 'hooks.dart';
import 'ports.dart';
import 'queue.dart';
import 'state.dart';
import 'host_headers.dart';
import 'uuid.dart';

class CoreConfig {
  CoreConfig({
    required this.apiKey,
    required this.apiHost,
    required this.http,
    required this.store,
    required this.libName,
    required this.libVersion,
    this.now,
    this.consentMode = ConsentMode.optOut,
    this.queueBeforeConsent = false,
    this.flushAt = 20,
    this.flushIntervalMs = 5000,
    this.maxQueueSize = 1000,
    this.maxRetries = 5,
    this.maxBatchSize = 100,
    this.retryBaseMs = 1000,
    this.networkAllowed,
    this.random,
    this.onDrop,
    this.beforeSend = const [],
    this.personProfiles = PersonProfiles.always,
    this.disableGeoip = false,
    this.disabled = false,
    this.sessionIdleMs = 30 * 60000,
    this.sessionMaxMs = 24 * 3600000,
    this.reuseAnonymousId = false,
    this.anonymousIdProvider,
    this.bootstrap,
    this.queueCipher,
    this.tracingHeaders = const [],
    this.debug = false,
    this.log,
  });
  final String apiKey;
  final String apiHost;
  final HttpPort http;

  /// Real persistence; the core gates it so nothing is written before consent.
  final KeyValueStore store;
  final String libName;
  final String libVersion;
  final Now? now;
  final ConsentMode consentMode;
  final bool queueBeforeConsent;
  final int flushAt;
  final int flushIntervalMs;
  final int maxQueueSize;
  final int maxRetries;
  final int maxBatchSize;
  final int retryBaseMs;

  /// Wi-Fi-only data mode: return false on cellular; events then wait in the queue.
  final bool Function()? networkAllowed;
  final double Function()? random;
  final void Function(List<WireEvent>, String)? onDrop;

  /// Ordered hooks run on every event before it is queued; see [HookChain].
  final List<BeforeSend> beforeSend;
  final PersonProfiles personProfiles;

  /// Ask the server not to geolocate events (`$geoip_disable`).
  final bool disableGeoip;

  /// Kill switch: nothing is captured.
  final bool disabled;
  final int sessionIdleMs;
  final int sessionMaxMs;

  /// Keep the anonymous id across reset().
  final bool reuseAnonymousId;
  final String Function()? anonymousIdProvider;
  final Bootstrap? bootstrap;

  /// Encrypt the persisted queue at rest (optional).
  final QueueCipher? queueCipher;

  /// Own-backend hosts that receive `X-Lucida-*` headers via [Core.tracing].
  final List<String> tracingHeaders;
  final bool debug;
  final void Function(String)? log;
}

/// Platform-agnostic client: identity, sessions, consent gating, super props, groups, queue.
class Core {
  Core(this.c) {
    now = c.now ?? () => DateTime.now().millisecondsSinceEpoch;
    consent = Consent(c.store, mode: c.consentMode, queueBeforeConsent: c.queueBeforeConsent);
    gated = GatedStore(c.store, () => consent.has('analytics'));
    debug = c.debug;
    identity = Identity(gated, now,
        newId: c.anonymousIdProvider, bootstrap: c.bootstrap, reuseAnonymousId: c.reuseAnonymousId);
    session = SessionManager(gated, now, idleMs: c.sessionIdleMs, maxMs: c.sessionMaxMs);
    _person = PersonMode(gated, c.personProfiles);
    _hooks = HookChain(c.beforeSend, debugLog);
    tracing = TracingHeaders(c.tracingHeaders, c.apiHost, () => consent.has('analytics'),
        () => (distinctId: distinctId, sessionId: session.touch()));
    _props = SuperProps(gated);
    _groups = Groups(gated);
    queue = EventQueue(
      http: c.http,
      url: '${c.apiHost.replaceAll(RegExp(r'/+$'), '')}/v1/batch',
      apiKey: c.apiKey,
      store: c.queueCipher == null
          ? c.store
          : EncryptedStore(c.store, c.queueCipher!,
              {'lc_queue'}, ['lc_queue.']), // raw: events only reach the queue after consent, and a revoke must really delete it
      now: now,
      flushAt: c.flushAt,
      flushIntervalMs: c.flushIntervalMs,
      maxQueueSize: c.maxQueueSize,
      maxRetries: c.maxRetries,
      maxBatchSize: c.maxBatchSize,
      retryBaseMs: c.retryBaseMs,
      networkAllowed: c.networkAllowed,
      random: c.random,
      onDrop: c.onDrop,
    );
  }

  final CoreConfig c;
  late final Now now;
  late final Consent consent;
  late final GatedStore gated;
  late final Identity identity;
  late final SessionManager session;
  late final EventQueue queue;
  late final SuperProps _props;
  late final Groups _groups;
  late final PersonMode _person;
  late final HookChain _hooks;
  late final TracingHeaders tracing;
  bool debug = false;
  final List<WireEvent> _pre = [];
  final List<void Function(WireEvent)> _listeners = [];

  /// Consent-gated storage for modules.
  KeyValueStore get storage => gated;
  String get distinctId => identity.distinctId;
  Map<String, String>? get groups => _groups.all();
  String get anonymousId => identity.anonymousId;
  String? get anonDistinctId => identity.priorAnonId;
  bool get isOptedOut => !consent.has('analytics');

  void debugLog(String msg) {
    if (debug) (c.log ?? (m) => print('[lucida] $m'))(msg);
  }

  /// Observe every event that passes the consent gate.
  void onCaptured(void Function(WireEvent) fn) => _listeners.add(fn);

  /// Extra properties for an event name (flag values); the caller's own properties win.
  Map<String, dynamic>? Function(String event)? enricher;

  WireEvent? capture(String event,
      [Map<String, dynamic> props = const {}, Map<String, dynamic>? set, Map<String, dynamic>? setOnce]) {
    if (c.disabled) return null;
    final granted = consent.has('analytics');
    if (!granted && !(consent.pending && consent.queueBeforeConsent)) return null;
    // Person writes are blocked in `never` mode and mark the device identified in `identifiedOnly` mode.
    final writes = (set?.isNotEmpty ?? false) || (setOnce?.isNotEmpty ?? false);
    if (writes && _person.blocksPersonWrites) debugLog('personProfiles=never: ignoring \$set/\$set_once on $event');
    if (writes || event == '\$identify' || event == '\$create_alias' || event == '\$groupidentify') {
      _person.markIdentified();
    }
    final sid = session.touch();
    final g = _groups.all();
    final blocked = _person.blocksPersonWrites;
    final e = <String, dynamic>{
      'uuid': uuidv7(now()),
      'event': event,
      'distinct_id': identity.distinctId,
      'timestamp': DateTime.fromMillisecondsSinceEpoch(now(), isUtc: true).toIso8601String(),
      'properties': {
        ...?enricher?.call(event),
        ..._props.all(),
        ...props,
        '\$session_id': sid,
        '\$window_id': session.windowId,
        '\$lib': c.libName,
        '\$lib_version': c.libVersion,
        if (_person.personless(event)) '\$process_person_profile': false,
        if (c.disableGeoip) '\$geoip_disable': true,
      },
      if (!blocked && set != null && set.isNotEmpty) '\$set': set,
      if (!blocked && setOnce != null && setOnce.isNotEmpty) '\$set_once': setOnce,
      if (g != null) '\$groups': g,
    };
    final out = _hooks.run(e);
    if (out == null) return null;
    for (final l in _listeners) {
      l(out);
    }
    if (granted) {
      queue.enqueue(out);
    } else if (_pre.length < c.maxQueueSize) {
      _pre.add(out);
    }
    return out;
  }

  void identify(String id, [Map<String, dynamic>? set, Map<String, dynamic>? setOnce]) {
    if (_person.blocksPersonWrites) return debugLog('personProfiles=never: identify ignored');
    final r = identity.identify(id);
    if (r != null || set != null || setOnce != null) capture('\$identify', r ?? {}, set, setOnce);
  }

  WireEvent? alias(String alias, [String? original]) {
    if (_person.blocksPersonWrites) {
      debugLog('personProfiles=never: alias ignored');
      return null;
    }
    return capture('\$create_alias', {'alias': alias, 'distinct_id': original ?? distinctId});
  }

  /// Update person properties without an event of your own (sends a `$set` event).
  WireEvent? setPersonProperties([Map<String, dynamic>? set, Map<String, dynamic>? setOnce]) {
    if (_person.blocksPersonWrites) {
      debugLog('personProfiles=never: setPersonProperties ignored');
      return null;
    }
    return capture('\$set', const {}, set, setOnce);
  }

  void reset() {
    _person.reset();
    identity.reset();
    _props.clear();
    _groups.clear();
    session.reset();
  }

  void register(Map<String, dynamic> p) => _props.register(p);
  void registerOnce(Map<String, dynamic> p) => _props.registerOnce(p);
  void unregister(String key) => _props.unregister(key);

  void group(String type, String key, [Map<String, dynamic>? properties]) {
    _groups.set(type, key);
    capture('\$groupidentify', {'\$group_type': type, '\$group_key': key, '\$group_set': properties ?? {}});
  }

  /// Screen view: `$screen` with `$screen_name`.
  void screen(String name, [Map<String, dynamic> props = const {}]) =>
      capture('\$screen', {...props, '\$screen_name': name});

  /// App opened through a URL / link: `$deep_link_opened` with the url, its query parameters and the referrer.
  WireEvent? deepLink(String url, [String? referrer]) {
    final u = Uri.tryParse(url);
    return capture('\$deep_link_opened', {
      'url': url,
      'query': u?.queryParameters ?? <String, String>{},
      if (referrer != null) 'referrer': referrer,
    });
  }

  /// Record a consent decision. Granting analytics releases state and held events; revoking drops them.
  void setConsent(Map<String, bool> update) {
    final was = consent.has('analytics');
    final will = update['analytics'] ?? was;
    if (was && !will) {
      capture('\$opt_out');
      queue.flush();
    }
    consent.set(update);
    if (!was && will) {
      gated.flushBuffered();
      for (final e in _pre.toList()) {
        queue.enqueue(e);
      }
      _pre.clear();
      capture('\$opt_in');
    } else if (was && !will) {
      queue.clear();
    }
    if (!will) {
      _pre.clear();
      gated.discardBuffered();
    }
  }

  void optIn() => setConsent({'analytics': true, 'replay': true, 'marketing': true});
  void optOut() => setConsent({'analytics': false, 'replay': false, 'marketing': false});
  Future<void> flush() => queue.flush();
  Future<void> shutdown() => queue.shutdown();
}
