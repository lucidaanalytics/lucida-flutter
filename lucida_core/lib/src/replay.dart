import 'dart:async';
import 'dart:convert';

import 'core.dart';
import 'replay_policy.dart';
import 'wireframe.dart';

/// Periodic wireframe recorder (LC-EXP-9). Each [tick] snapshots the widget tree through a [WidgetTreeSource]; when the
/// structure changed since the last one (or the session rotated) it sends Meta + FullSnapshot, preceded by a
/// `navigation` marker on a screen change. Chunks go to `POST /v1/replay` as
/// `{api_key, session_id, window_id, seq, events}`; `seq` is monotonic per window and resets when the session rotates.
/// Needs analytics AND replay consent, so nothing is read from the tree before the user agreed.
///
/// Gates, in order: consent, project kill switch + sample rate (`GET /v1/config`, tightening only), linked flag, pause,
/// screen allow/deny list, then [minDurationMs] (chunks wait in memory; dropped if the session ends or [stop] is called first).
class ReplayRecorder {
  ReplayRecorder(this.core, this.source,
      {this.snapshotInterval = const Duration(seconds: 5),
      this.maskTextContent = true,
      this.maskAllTextInputs = true,
      this.maskAllImages = true,
      this.sampleRate = 1.0,
      this.maxBytes = 5000000,
      this.minDurationMs = 0,
      this.useRemoteConfig = true,
      this.linkedFlag,
      this.flagEnabled,
      this.screenAllowList = const [],
      this.screenDenyList = const [],
      this.captureTouches = true});

  final Core core;
  final WidgetTreeSource source;
  final Duration snapshotInterval;

  /// Text is starred unless false; inputs and sensitive widgets are never included.
  final bool maskTextContent;

  /// Input values are starred unless false (only honoured for non-obscured fields the tree source chose to read).
  final bool maskAllTextInputs;
  final bool maskAllImages;

  /// 0..1, decided once per session. [snapshotInterval] doubles as the throttle delay between captures.
  final double sampleRate;

  /// Largest chunk sent (the gateway accepts 10 MB decompressed).
  final int maxBytes;

  /// Hold chunks until the session has been recorded this long; a session that ends sooner is never sent. 0 = off.
  final int minDurationMs;

  /// Fetch `GET /v1/config` for the kill switch, sample rate and minimum duration (can only tighten).
  final bool useRemoteConfig;

  /// Start recording only while this flag is on (read through [flagEnabled]).
  final String? linkedFlag;
  final bool Function(String key)? flagEnabled;

  /// Only these screens are recorded (empty = all); the deny list wins and recording pauses on a denied screen.
  final List<String> screenAllowList;
  final List<String> screenDenyList;

  /// Record tap positions (via [tap]); never what was typed.
  final bool captureTouches;

  Timer? _timer;
  String _screen = 'Unknown';
  String? _lastFp;
  String? _lastScreen;
  String? _lastSession;
  int _seq = 0;
  bool _paused = false;
  RemoteReplayConfig? _remote;
  bool _remoteLoaded = false;
  int _sessionStart = 0;
  final List<List<Map<String, dynamic>>> _held = [];
  static const _maxHeld = 20; // shortcut: bounded memory, oldest chunks beyond this are dropped
  WireSnapshot? _lastSnap;
  final List<Map<String, dynamic>> _touches = [];

  void setScreen(String name) => _screen = name;

  void start() => _timer ??= Timer.periodic(snapshotInterval, (_) => tick());

  /// Keeps the loop alive but captures nothing until [resume].
  void pause() => _paused = true;
  void resume() => _paused = false;

  /// Loop running and not paused, consent allows it, this session is sampled in, the linked flag (if any) is on and the screen is allowed.
  bool get isActive =>
      _timer != null &&
      !_paused &&
      core.consent.has('analytics') &&
      core.consent.has('replay') &&
      _sampled(core.session.touch()) &&
      _gateOpen(_screen);

  bool _gateOpen(String screen) {
    final f = linkedFlag;
    if (f != null && !(flagEnabled?.call(f) ?? false)) return false;
    return ReplayPolicy.screenAllowed(screen, screenAllowList, screenDenyList);
  }

  bool _sampled(String sessionId) {
    final r = ReplayPolicy.sampleRate(sampleRate, _remote);
    if (r >= 1) return true;
    if (r <= 0) return false;
    return (sessionId.hashCode & 0x7fffffff) % 10000 / 10000.0 < r;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _held.clear(); // the session ends before it reached the minimum duration
  }

  String get _base => core.c.apiHost.replaceAll(RegExp(r'/+$'), '');

  Future<void> _loadRemote() async {
    if (!useRemoteConfig || _remoteLoaded) return;
    _remoteLoaded = true;
    try {
      final r = await core.c.http.send('GET', '$_base/v1/config?api_key=${Uri.encodeQueryComponent(core.c.apiKey)}');
      if (r.status >= 200 && r.status < 300) _remote = RemoteReplayConfig.parse(r.body); // unreachable: local settings stand
    } catch (_) {}
  }

  /// A tap at screen point (x, y); needs replay consent and a sent snapshot. Never records what was typed.
  void tap(double x, double y) {
    final snap = _lastSnap;
    if (!captureTouches || snap == null || _paused || !core.consent.has('analytics') || !core.consent.has('replay')) return;
    if (_touches.length < 500) _touches.add(tapEvent(snap, x, y, core.now()));
  }

  /// One capture pass; the timer calls it, tests call it directly.
  Future<void> tick() async {
    if (!core.consent.has('analytics') || !core.consent.has('replay')) {
      _lastFp = null; // revoking drops state so a re-grant starts clean
      _lastSnap = null;
      _touches.clear();
      _held.clear();
      return;
    }
    await _loadRemote();
    final sid = core.session.touch();
    if (!_sampled(sid)) return;
    if (_paused || !_gateOpen(_screen)) {
      // Leaving a gated screen: the next allowed tick starts from a fresh snapshot; touches on it are dropped.
      _lastFp = null;
      _lastSnap = null;
      _touches.clear();
      return;
    }
    final WireSnapshot? snap;
    try {
      snap = source.snapshot(_screen);
    } catch (_) {
      return; // a failing tree walk must never affect the app
    }
    if (snap == null) return;
    final rotated = sid != _lastSession;
    if (rotated) {
      _seq = 0;
      _lastSession = sid;
      _sessionStart = core.now();
      _held.clear(); // a session cut short is dropped
    }
    final events = <Map<String, dynamic>>[..._touches];
    _touches.clear();
    final fp = jsonEncode(fullSnapshotEvent(snap, mask: true, ms: 0, maskInputs: true, maskImages: true));
    if (rotated || fp != _lastFp) {
      _lastFp = fp;
      final ms = core.now();
      events.add(metaEvent(snap, ms));
      if (snap.screen != _lastScreen) {
        events.add(navigationEvent(snap, ms));
        _lastScreen = snap.screen;
      }
      events.add(fullSnapshotEvent(snap,
          mask: maskTextContent, ms: ms, maskInputs: maskAllTextInputs, maskImages: maskAllImages));
      _lastSnap = snap;
    }
    if (events.isEmpty) return;
    final minMs = ReplayPolicy.minDurationMs(minDurationMs, _remote);
    if (minMs > 0 && core.now() - _sessionStart < minMs) {
      _held.add(events);
      if (_held.length > _maxHeld) _held.removeAt(0);
      return;
    }
    final backlog = List.of(_held);
    _held.clear();
    for (final chunk in [...backlog, events]) {
      await _send(chunk, sid);
    }
  }

  Future<void> _send(List<Map<String, dynamic>> events, String sid) async {
    final body = jsonEncode({
      'api_key': core.c.apiKey,
      'session_id': sid,
      'window_id': core.session.windowId,
      'seq': _seq,
      'events': events,
    });
    if (body.length > maxBytes) return;
    final r = await core.c.http
        .send('POST', '$_base/v1/replay?compression=gzip', body: body, headers: {'Content-Type': 'application/json'}, gzip: true);
    if (r.status >= 200 && r.status < 300) {
      _seq++;
    } else {
      _lastFp = null; // retry as a fresh snapshot next tick
    }
  }
}
