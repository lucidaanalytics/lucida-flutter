import 'core.dart';

/// App lifecycle events: `$app_installed` / `$app_updated` (version change) on first launch,
/// `$app_opened` on launch and foreground, `$app_backgrounded` (and a flush) on background.
class Lifecycle {
  Lifecycle(this._core, {required this.version, this.build});
  final Core _core;
  final String version;
  final String? build;
  static const _key = 'lc_app_version';

  Map<String, dynamic> get _app => {'\$app_version': version, if (build != null) '\$app_build': build};

  void launched() {
    final prev = _core.storage.get(_key);
    if (prev == null) {
      _core.capture('\$app_installed', _app);
    } else if (prev != version) {
      _core.capture('\$app_updated', {..._app, '\$previous_app_version': prev});
    }
    _core.storage.set(_key, version);
    _core.capture('\$app_opened', {..._app, 'from_background': false});
  }

  void foregrounded() => _core.capture('\$app_opened', {..._app, 'from_background': true});

  Future<void> backgrounded() {
    _core.capture('\$app_backgrounded', _app);
    return _core.flush();
  }
}
