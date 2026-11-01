import 'package:flutter/widgets.dart';
import 'package:lucida_core/lucida_core.dart';

/// Holds the client for the widget tree and maps app lifecycle to `$app_opened` / `$app_backgrounded`.
/// Call `client.start()` before `runApp` (it emits the launch events).
class LucidaProvider extends StatefulWidget {
  const LucidaProvider({super.key, required this.client, required this.child});
  final Lucida client;
  final Widget child;

  static Lucida of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Inherited>()!.client;

  @override
  State<LucidaProvider> createState() => _State();
}

class _State extends State<LucidaProvider> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) widget.client.lifecycle.backgrounded();
    if (s == AppLifecycleState.resumed) widget.client.lifecycle.foregrounded();
  }

  @override
  Widget build(BuildContext context) => _Inherited(client: widget.client, child: widget.child);
}

class _Inherited extends InheritedWidget {
  const _Inherited({required this.client, required super.child});
  final Lucida client;
  @override
  bool updateShouldNotify(_Inherited old) => old.client != client;
}
