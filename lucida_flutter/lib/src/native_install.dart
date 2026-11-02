import 'package:flutter/services.dart';
import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_core/lucida_io.dart';

const _channel = MethodChannel('lucida_flutter/install');

/// Install attribution for `Lucida(..., installSource: nativeInstallSource())`: Play Install Referrer on Android,
/// AdServices token on iOS (resolved over [http], default dart:io with a 10 s timeout). Without the native plugin
/// or on any failure it degrades to no extra props.
InstallSource nativeInstallSource({HttpPort? http}) => installSourceFrom(
      () => _channel.invokeMapMethod<dynamic, dynamic>('installInfo'),
      http ?? IoHttp(timeout: const Duration(seconds: 10)),
    );

/// The Flutter entry point: a [Lucida] whose first-open `$app_installed` carries Play Install Referrer / AdServices
/// attribution by default. `installAttribution: false` opts out; `installSource` overrides the native source.
Lucida createLucida(CoreConfig config,
        {required String appVersion,
        String? appBuild,
        List<Map<String, dynamic>> flagDefinitions = const [],
        Map<String, dynamic> deviceProperties = const {},
        GuidesConfig? guides,
        FlagOptions flagOptions = const FlagOptions(),
        AutocaptureConfig autocaptureConfig = const AutocaptureConfig(),
        bool installAttribution = true,
        InstallSource? installSource}) =>
    Lucida(config,
        appVersion: appVersion,
        appBuild: appBuild,
        flagDefinitions: flagDefinitions,
        deviceProperties: deviceProperties,
        guides: guides,
        flagOptions: flagOptions,
        autocaptureConfig: autocaptureConfig,
        installSource: installAttribution ? (installSource ?? nativeInstallSource()) : null);
