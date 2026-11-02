/// P-L12 controlled exposure: a listed field's value, RSA-OAEP-SHA256 encrypted with the project key, so only an
/// audited reveal on the server can read it. Identical values are sent once per session (an in-memory SHA-256 set,
/// never persisted or sent). Encryption failure sends nothing.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'replay_policy.dart';
import 'rsa_oaep.dart';

const sensitiveMaxPlainBytes = 190;

/// UTF-8 of [value], cut to at most [max] bytes on a code point boundary; `truncated` is true when cut.
({Uint8List bytes, bool truncated}) truncateUtf8(String value, [int max = sensitiveMaxPlainBytes]) {
  final out = BytesBuilder(copy: false);
  for (final r in value.runes) {
    final b = utf8.encode(String.fromCharCode(r));
    if (out.length + b.length > max) return (bytes: out.takeBytes(), truncated: true);
    out.add(b);
  }
  return (bytes: out.takeBytes(), truncated: false);
}

/// Standard base64 of the RSA-OAEP-SHA256 ciphertext of [plain] under [key] (`n` / `e`), or null on any failure.
String? encryptSensitive(List<int> plain, ExposureKey key, {List<int>? seed}) {
  try {
    final n = bytesToBigInt(base64Url.decode(base64Url.normalize(key.n)));
    final e = bytesToBigInt(base64Url.decode(base64Url.normalize(key.e)));
    if (n <= BigInt.zero || e <= BigInt.zero) return null;
    return base64.encode(rsaOaepEncrypt(plain, n, e, seed: seed));
  } catch (_) {
    return null;
  }
}

class SensitiveCapture {
  final _seen = <String>{};
  String? _session;

  /// `$sensitive_capture` properties, or null when this value was already sent this session or encryption failed.
  Map<String, dynamic>? properties(String field, String value, String screen, ExposureKey key, String sessionId) {
    final digest = sha256.convert(utf8.encode('$field\u0000$value')).toString();
    if (_session != sessionId) {
      _seen.clear();
      _session = sessionId;
    }
    if (_seen.contains(digest)) return null;
    final t = truncateUtf8(value);
    final ct = encryptSensitive(t.bytes, key);
    if (ct == null) return null;
    _seen.add(digest);
    return {
      '\$exposure_field': field,
      '\$exposure_kid': key.kid,
      '\$exposure_ciphertext': ct,
      '\$screen_name': screen,
      if (t.truncated) '\$exposure_truncated': true,
    };
  }
}
