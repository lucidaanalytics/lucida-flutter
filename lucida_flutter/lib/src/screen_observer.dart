import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// NavigatorObserver that emits `$screen` for every named route push / pop-back.
class LucidaScreenObserver extends NavigatorObserver {
  LucidaScreenObserver(this.client, {this.replay});
  final Lucida client;

  /// When replay is on, keeps its screen name in step with navigation.
  final ReplayRecorder? replay;

  void _screen(Route<dynamic>? r) {
    final name = r?.settings.name;
    if (name == null || name.isEmpty) return;
    client.screen(name);
    replay?.setScreen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) => _screen(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previous) => _screen(previous);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _screen(newRoute);
}
