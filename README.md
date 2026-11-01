# Lucida Flutter / Dart SDK

Two packages:

- `lucida_core`: **pure Dart**, no Flutter dependency. Capture queue (persistent, batching, gzip, retry/backoff),
  identity, sessions, consent, flags (local eval over the shared vectors plus `POST /v1/flags`),
  lifecycle events, screen views. `dart test` runs it; `make sdk-dart` runs format, analyze and tests.
- `lucida_flutter`: thin Flutter bindings (`LucidaProvider` with app-lifecycle mapping, `LucidaScreenObserver`
  `NavigatorObserver`, `PrefsStore` over SharedPreferences). **It is not compiled or tested
  here**: Flutter is not installed on the build host. It is ~150 lines of glue and everything with logic lives in
  `lucida_core`.

```dart
final store = PrefsStore(await SharedPreferences.getInstance());
final lucida = Lucida(
  CoreConfig(apiKey: 'lc_pk_...', apiHost: 'https://ingest.example.com',
      http: IoHttp(), store: store, libName: 'lucida-flutter', libVersion: '0.1.0',
      consentMode: ConsentMode.optIn),
  appVersion: '1.2.3',
);
await lucida.start();                       // $app_installed/$app_updated/$app_opened, flags
runApp(LucidaProvider(client: lucida, child: MaterialApp(navigatorObservers: [LucidaScreenObserver(lucida)])));
lucida.optIn();
```

`IoHttp` is exported from `package:lucida_core/lucida_io.dart` (dart:io; keeps the core barrel platform-free).

## Wire contract

Same as `sdks/android/README.md` and `sdks/browser/README.md`: `POST /v1/batch?compression=gzip`
`{api_key, batch, sent_at}`, UUIDv7 event `uuid`, at-least-once (events stay in the persisted queue until a 2xx),
opt-in mode stores nothing before `optIn()`, `$screen` / `$app_*` / `$feature_flag_called` events.

## Session replay (wireframe)

`lucida_core` has the whole pipeline, testable with `dart test`: `WidgetTreeSource` (port: the current widget tree as a
`WireSnapshot` of `WireNode`s), the rrweb encoder (`metaEvent`, `navigationEvent`, `fullSnapshotEvent`; same shape as the iOS
and Android SDKs, decoded by `crates/lc-replay`) and `ReplayRecorder` (consent gate: analytics AND replay; session/window ids;
`seq` that resets on session rotation; structure dedupe; `POST /v1/replay?compression=gzip`). Text is starred by default;
inputs and sensitive nodes never carry text.

```dart
final replay = ReplayRecorder(lucida.core, FlutterWidgetTree())..start();   // lucida_flutter
MaterialApp(navigatorObservers: [LucidaScreenObserver(lucida, replay: replay)]);
lucida.core.consent.set({'replay': true});   // replay needs its own consent
```

Screenshot mode: wrap the app in `LucidaReplayBoundary` and pass `screenshots: FlutterScreenshots()` to `ReplayRecorder`.
Each tick draws the boundary (`toImageSync`, same frame as the tree walk), paints text, inputs, images, obscured fields and
`LucidaMask`/`LucidaSensitive` subtrees over on a `PictureRecorder` canvas, and only then encodes PNG
(`test/screenshot_test.dart` checks the painted pixels). Platform views come out blank.

`FlutterWidgetTree` (in `lucida_flutter`, walks `Element`/`RenderBox`; wrap secrets in `LucidaSensitive`) is **not
compiled or tested here**: Flutter is not installed on the build host. Treat it as a reference implementation of the port and
verify it on a device.

## Hooks, person profiles, flags, privacy

Config lives on `CoreConfig` (queue/network knobs: `flushAt`, `flushIntervalMs`, `maxQueueSize`, `maxBatchSize`, `maxRetries`,
`retryBaseMs`, `networkAllowed` for Wi-Fi-only, `sessionIdleMs`/`sessionMaxMs`, `disableGeoip`, `disabled`, `queueCipher`; request
timeout is `IoHttp(timeout:)`) and the `Lucida(...)` facade (`flagOptions`, `autocaptureConfig`).

- `beforeSend`: ordered `WireEvent? Function(WireEvent)` hooks; return a changed event to amend, `null` to drop. A hook that
  throws is logged (when `debug`) and skipped: the event continues as it was before that hook. `sampleHook(0.1)` keeps ~10% and
  adds `$sample_rate`.
- `personProfiles`: `always` (default), `identifiedOnly` (events carry `$process_person_profile: false` until identify, alias,
  group or a person-property write; persisted, cleared by `reset()`), `never` (identify/alias/setPersonProperties are no-ops with a debug warning).
- Flags: `bootstrap: Bootstrap(distinctId:, isIdentified:, flags:, payloads:)`; `FlagOptions(sendFeatureFlagEvent:, preload:,
  evaluationContexts:)`; `flags.onFeatureFlags(fn)`; `flags.setPersonPropertiesForFlags(props, reload: true)`,
  `setGroupPropertiesForFlags`, and the reset variants.
- Person helpers: `setPersonProperties`, `capture(event, props, set, setOnce)`, `anonymousId`, `reuseAnonymousId`,
  `anonymousIdProvider`, `isOptedOut`, `register*`, `setConsent`, `debug(bool)`, `deepLink(url, referrer)` (route your link
  handler into it; there is no platform hook in Dart).
- Tracing headers: `tracingHeaders: ['api.example.com', '.corp.io']`, then `addTracingHeaders(request, lucida.tracing)` from
  `lucida_io.dart` (never to the Lucida host; analytics consent required).
- Autocapture: `AutocaptureConfig(enabled: true, ignoreLabels:, maxElements:, propsAllowList:, rageTap:)` plus the
  `LucidaAutocapture(client:, child:)` widget (hit-test based: paragraph text as label, text fields geometry only). `LucidaMark(noCapture: true)`
  excludes a subtree; `LucidaMark(name:, props:)` names it. `$autocapture` taps and `$rageclick`. Field values are never read.
- Replay: `ReplayRecorder(..., maskTextContent:, maskAllTextInputs:, maskAllImages:, sampleRate:, snapshotInterval:)` (the interval is
  the throttle delay), `start()` / `stop()` / `isActive`; `LucidaUnmask` shows a subtree despite the masks, platform views
  (`AndroidView`, `UiKitView`, `HtmlElementView`) are frame-only by default (`FlutterWidgetTree(maskPlatformViews:)`), obscured
  fields and `LucidaSensitive` never carry text. The tree walker reads field values only with `FlutterWidgetTree(maskAllTextInputs: false)`
  (pass the same value to `ReplayRecorder`); obscured fields and `LucidaMask` subtrees stay empty.

Not built: push registration (needs a scope decision). `lucida_flutter` has `flutter test` coverage (`cd sdks/flutter/lucida_flutter && flutter test`).

## Gaps

- `lucida_flutter` is uncompiled (see above); `PrefsStore` writes are fire-and-forget.
- Native-isolate background flush is not wired; the queue flushes on `paused` via `LucidaProvider`.

---

This repository is a read-only mirror of the Lucida monorepo (synced by a script, never edited by hand); releases and provenance attestations are built here by GitHub Actions. Issues are welcome, changes land upstream.
