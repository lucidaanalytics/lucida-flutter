import 'dart:convert';
import 'dart:io';

import 'ports.dart';
import 'host_headers.dart';

/// dart:io adapter for [HttpPort]; gzips the body when asked. Network errors become status 0.
class IoHttp implements HttpPort {
  IoHttp({this.timeout = const Duration(seconds: 15)});
  final Duration timeout;

  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        if (gzip) {
          req.headers.set('Content-Encoding', 'gzip');
          req.add(GZipCodec().encode(bytes));
        } else {
          req.add(bytes);
        }
      }
      final res = await req.close().timeout(timeout);
      return HttpResult(res.statusCode, await res.transform(utf8.decoder).join());
    } catch (_) {
      return const HttpResult(0);
    } finally {
      client.close(force: true);
    }
  }
}

/// Adds `X-Lucida-*` tracing headers to an outgoing dart:io request when its host is on the allow-list.
void addTracingHeaders(HttpClientRequest req, TracingHeaders t) =>
    t.headersFor(req.uri.toString(), baggage: req.headers['baggage']?.join(',')).forEach(req.headers.set);
