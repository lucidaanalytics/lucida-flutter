import 'package:lucida_core/lucida_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [KeyValueStore] over SharedPreferences. Load the instance once at startup
/// (`PrefsStore(await SharedPreferences.getInstance())`); reads are then synchronous, writes fire-and-forget.
class PrefsStore implements KeyValueStore {
  PrefsStore(this._p);
  final SharedPreferences _p;

  @override
  String? get(String key) => _p.getString('lucida.$key');
  @override
  void set(String key, String value) => _p.setString('lucida.$key', value);
  @override
  void remove(String key) => _p.remove('lucida.$key');
}
