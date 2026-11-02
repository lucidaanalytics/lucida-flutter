import 'core.dart';
import 'install_attribution.dart';

/// App lifecycle events: `$app_installed` / `$app_updated` (version change) on first launch,
/// `$app_opened` on launch and foreground, `$app_backgrounded` (and a flush) on background.
class Lifecycle {
  Lifecycle(this._core, {required this.version, this.build, this.installSource});
  final Core _core;
  final String version;
  final String? build;

  /// First-open install attribution; `$app_installed` is sent when it completes. Null = send immediately.
  final InstallSource? installSource;
  static const _key = 'lc_app_version';

  Map<String, dynamic> get _app => {'\$app_version': version, if (build != null) '\$app_build': build};

  void launched() {
    final prev = _core.storage.get(_key);
    if (prev == null) {
      _installed();
    } else if (prev != version) {
      _core.capture('\$app_updated', {..._app, '\$previous_app_version': prev});
    }
    _core.storage.set(_key, version);
    _core.capture('\$app_opened', {..._app, 'from_background': false});
  }

  // The version key is stored right after, so the install fires once per install even if the source is slow.
  void _installed() {
    final src = installSource;
    if (src == null) {
      _core.capture('\$app_installed', _app);
      return;
    }
    src().catchError((_) => <String, dynamic>{}).then((extra) => _core.capture('\$app_installed', {..._app, ...extra}));
  }

  void foregrounded() => _core.capture('\$app_opened', {..._app, 'from_background': true});

  Future<void> backgrounded() {
    _core.capture('\$app_backgrounded', _app);
    return _core.flush();
  }
}
