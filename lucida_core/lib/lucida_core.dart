/// Barrel: the public surface of the Lucida mobile core. Platform-free; I/O arrives via ports.
library;

export 'src/autocapture.dart' show Autocapture, AutocaptureConfig, RageTapConfig, TapElement;
export 'src/client.dart';
export 'src/consent.dart' show ConsentMode;
export 'src/core.dart' show Core, CoreConfig;
export 'src/flag_enrich.dart' show flagEventProps;
export 'src/flag_eval.dart' show evaluateAll, evaluateFlag, flagHash, hashInput, requiresServer;
export 'src/encrypted_store.dart' show EncryptedStore, QueueCipher;
export 'src/flag_options.dart' show Bootstrap, FlagDetails, FlagMeta, FlagOptions, FlagsStatus;
export 'src/flags.dart' show Flags;
export 'src/hooks.dart' show BeforeSend, HookChain, PersonProfiles, sampleHook;
export 'src/guide_rules.dart' show GuideRules;
export 'src/guide_theme.dart' show GuidePlacement, GuideTheme, GuideTokens;
export 'src/guides.dart'
    show
        AnchoredGuidePresenter,
        GuideAnchor,
        GuideButton,
        GuidePresenter,
        GuideStep,
        GuidesConfig,
        GuidesService,
        MobileGuide;
export 'src/install_attribution.dart' show InstallSource, appStoreInstallProps, installReferrerProps, installSourceFrom;
export 'src/lifecycle.dart' show Lifecycle;
export 'src/ports.dart';
export 'src/queue.dart' show EventQueue, WireEvent;
export 'src/dead_swipe.dart' show deadSwipeDecision, deadSwipeMinDistance, swipeDirection;
export 'src/replay.dart' show ReplayRecorder;
export 'src/replay_masking.dart' show applyPrivacy, compilePatterns, maskPatterns;
export 'src/replay_policy.dart' show ExposureKey, RemoteReplayConfig, ReplayPolicy;
export 'src/rsa_oaep.dart' show rsaOaepEncrypt;
export 'src/sensitive_capture.dart' show encryptSensitive, truncateUtf8;
export 'src/screenshot.dart'
    show MaskRect, ScreenshotMaskPlan, ScreenshotSource, screenshotPlan, screenshotSnapshotEvent;
export 'src/retry.dart' show backoffDelay, isRetryable;
export 'src/host_headers.dart' show TracingHeaders;
export 'src/wireframe.dart'
    show
        WidgetTreeSource,
        WireKind,
        WireNode,
        WireSnapshot,
        fullSnapshotEvent,
        maskText,
        metaEvent,
        navigationEvent,
        nodeAt,
        tapEvent;
