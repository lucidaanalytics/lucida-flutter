/// Adds `X-Lucida-Distinct-Id` / `X-Lucida-Session-Id` to requests for your own backend hosts so server events
/// join this device's session. `hosts` entries match exactly, or as a suffix when they start with a dot
/// (`.example.com`). Never added for the Lucida api host, and only while analytics consent is granted.
/// Servers must treat these headers as client-controlled, never as authentication.
class TracingHeaders {
  TracingHeaders(this.hosts, String apiHost, this._consent, this._ids)
      : _api = Uri.tryParse(apiHost)?.host.toLowerCase();
  final List<String> hosts;
  final String? _api;
  final bool Function() _consent;
  final ({String distinctId, String sessionId}) Function() _ids;

  bool _matches(String host) => hosts.any((h) {
        final x = h.toLowerCase();
        return x.startsWith('.') ? host.endsWith(x) : host == x;
      });

  Map<String, String> headersFor(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty || hosts.isEmpty || host == _api || !_matches(host) || !_consent()) return {};
    final ids = _ids();
    return {'X-Lucida-Distinct-Id': ids.distinctId, 'X-Lucida-Session-Id': ids.sessionId};
  }
}
