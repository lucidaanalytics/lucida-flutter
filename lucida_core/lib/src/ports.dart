/// Synchronous key/value persistence (SharedPreferences, file, memory). Adapters live in platform packages.
abstract class KeyValueStore {
  String? get(String key);
  void set(String key, String value);
  void remove(String key);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  String? get(String key) => data[key];
  @override
  void set(String key, String value) => data[key] = value;
  @override
  void remove(String key) => data.remove(key);
}

/// status 0 means a network failure.
class HttpResult {
  const HttpResult(this.status, [this.body = '']);
  final int status;
  final String body;
}

/// Port: how bytes leave the SDK. `gzip` asks the adapter to compress the body.
abstract class HttpPort {
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false});
}

typedef Now = int Function();
