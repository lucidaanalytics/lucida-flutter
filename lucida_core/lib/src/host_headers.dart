/// Adds `X-Lucida-Distinct-Id` / `X-Lucida-Session-Id` to requests for your own backend hosts so server events
/// join this device's session. `hosts` entries match exactly, or as a suffix when they start with a dot
/// (`.example.com`). Never added for the Lucida api host, and only while analytics consent is granted.
/// Servers must treat these headers as client-controlled, never as authentication.
/// The same requests carry W3C `baggage: lucida.session_id=<id>` (merged into the app's own baggage) so Watchtower links
/// its spans, network timings and logs to this session: the Watchtower seam, Lucida captures no network or log data.
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

  /// [baggage] is the request's existing `baggage` value, kept (minus a stale Lucida entry) in the returned one.
  Map<String, String> headersFor(String url, {String? baggage}) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty || hosts.isEmpty || host == _api || !_matches(host) || !_consent()) return {};
    final ids = _ids();
    return {
      'X-Lucida-Distinct-Id': ids.distinctId,
      'X-Lucida-Session-Id': ids.sessionId,
      'baggage': withBaggage(baggage, ids.sessionId),
    };
  }

  /// `lucida.session_id=<id>` appended to [existing] W3C baggage, replacing a stale Lucida entry.
  static String withBaggage(String? existing, String sessionId) => [
        ...(existing ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty && !s.startsWith('lucida.session_id=')),
        'lucida.session_id=$sessionId',
      ].join(',');
}
