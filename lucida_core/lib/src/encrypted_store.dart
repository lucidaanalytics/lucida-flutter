import 'ports.dart';

/// Port: at-rest encryption for the persisted queue (plug in a keystore-backed cipher).
abstract class QueueCipher {
  String encrypt(String plain);

  /// null when the value cannot be decrypted (key rotated, corrupt): the queue then starts empty.
  String? decrypt(String cipher);
}

/// Decorator: values under [_keys] are stored encrypted, everything else passes through.
class EncryptedStore implements KeyValueStore {
  EncryptedStore(this._inner, this._cipher, this._keys);
  final KeyValueStore _inner;
  final QueueCipher _cipher;
  final Set<String> _keys;

  @override
  String? get(String key) {
    final v = _inner.get(key);
    return v != null && _keys.contains(key) ? _cipher.decrypt(v) : v;
  }

  @override
  void set(String key, String value) => _inner.set(key, _keys.contains(key) ? _cipher.encrypt(value) : value);

  @override
  void remove(String key) => _inner.remove(key);
}
