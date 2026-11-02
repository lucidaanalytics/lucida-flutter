/// RSA-OAEP with SHA-256 for both the OAEP hash and MGF1 and an empty label (RFC 8017 7.1.1), in pure Dart (no new
/// dependency: SHA-256 from package:crypto, the modular exponentiation from [BigInt.modPow]). Encryption only: the
/// private key never exists on device.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _hLen = 32;

/// MGF1 with SHA-256: [len] bytes of mask from [seed].
Uint8List mgf1Sha256(List<int> seed, int len) {
  final out = BytesBuilder(copy: false);
  for (var c = 0; out.length < len; c++) {
    out.add(sha256.convert([...seed, (c >> 24) & 0xff, (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff]).bytes);
  }
  return Uint8List.fromList(out.takeBytes().sublist(0, len));
}

/// EME-OAEP encoding of [m] for a [k]-byte modulus with a 32-byte [seed]: 0x00 || maskedSeed || maskedDB, where
/// DB = SHA-256("") || zero padding || 0x01 || m. Throws [ArgumentError] when [m] is longer than k - 66 bytes.
Uint8List oaepEncode(List<int> m, int k, List<int> seed) {
  if (seed.length != _hLen) throw ArgumentError('seed must be 32 bytes');
  if (m.length > k - 2 * _hLen - 2) throw ArgumentError('message too long');
  final db = Uint8List(k - _hLen - 1);
  db.setRange(0, _hLen, sha256.convert(const <int>[]).bytes);
  db[db.length - m.length - 1] = 0x01;
  db.setRange(db.length - m.length, db.length, m);
  final dbMask = mgf1Sha256(seed, db.length);
  for (var i = 0; i < db.length; i++) {
    db[i] ^= dbMask[i];
  }
  final seedMask = mgf1Sha256(db, _hLen);
  final em = Uint8List(k);
  for (var i = 0; i < _hLen; i++) {
    em[1 + i] = seed[i] ^ seedMask[i];
  }
  em.setRange(1 + _hLen, k, db);
  return em;
}

BigInt bytesToBigInt(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x & 0xff);
  }
  return r;
}

/// Big-endian, left-padded with zeros to [len] bytes.
Uint8List bigIntToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  final ff = BigInt.from(0xff);
  for (var i = len - 1; i >= 0 && v > BigInt.zero; i--) {
    out[i] = (v & ff).toInt();
    v = v >> 8;
  }
  return out;
}

/// RSA-OAEP-SHA256 ciphertext of [plain] under the public key ([n], [e]): exactly as long as the modulus (256 bytes for
/// 2048-bit keys). [seed] is for tests; otherwise 32 bytes come from [Random.secure].
Uint8List rsaOaepEncrypt(List<int> plain, BigInt n, BigInt e, {List<int>? seed}) {
  final k = (n.bitLength + 7) ~/ 8;
  final rnd = seed == null ? Random.secure() : null;
  final s = seed ?? List<int>.generate(_hLen, (_) => rnd!.nextInt(256));
  return bigIntToBytes(bytesToBigInt(oaepEncode(plain, k, s)).modPow(e, n), k);
}
