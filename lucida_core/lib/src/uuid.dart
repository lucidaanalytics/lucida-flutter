import 'dart:math';

final _rng = Random.secure();

/// UUIDv7: 48-bit ms timestamp, version 7, random remainder.
String uuidv7(int nowMs) {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  for (var i = 0; i < 6; i++) {
    b[i] = (nowMs >> (8 * (5 - i))) & 0xff;
  }
  b[6] = 0x70 | (b[6] & 0x0f);
  b[8] = 0x80 | (b[8] & 0x3f);
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
