import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_core/src/rsa_oaep.dart';
import 'package:test/test.dart';

/// P-M17 masked screens, P-M46 text patterns and `$dead_swipe`, P-L12 controlled exposure.
class _Http implements HttpPort {
  final List<String> chunks = [];
  String configBody = '';
  @override
  Future<HttpResult> send(String method, String url,
      {String? body, Map<String, String> headers = const {}, bool gzip = false}) async {
    if (url.contains('/v1/replay')) {
      chunks.add(body!);
      return const HttpResult(200);
    }
    if (url.contains('/v1/config')) return HttpResult(200, configBody);
    return const HttpResult(200);
  }
}

class _Source implements WidgetTreeSource {
  String label = 'Order 1234';
  @override
  WireSnapshot? snapshot(String screen) => WireSnapshot(
        screen,
        100,
        200,
        WireNode(WireKind.view, 0, 0, 100, 200, children: [
          WireNode(WireKind.label, 10, 10, 50, 20, text: label),
          const WireNode(WireKind.label, 10, 40, 50, 20, text: 'open 42', unmask: true),
          const WireNode(WireKind.image, 10, 70, 50, 20, unmask: true),
        ]),
      );
}

class _Shots implements ScreenshotSource {
  final List<ScreenshotMaskPlan> plans = [];
  @override
  Future<String?> capture(ScreenshotMaskPlan plan) async {
    plans.add(plan);
    return 'AAAA';
  }
}

int _now = 1760000000000;

({Core core, _Http http, _Source src, List<WireEvent> events}) env() {
  final http = _Http();
  final core = Core(CoreConfig(
    apiKey: 'lc_pk_x',
    apiHost: 'https://ingest.test/',
    http: http,
    store: MemoryStore(),
    libName: 'lucida-dart',
    libVersion: '0.1.0',
    now: () => _now,
    flushIntervalMs: 60000,
    random: () => 0,
  ));
  final events = <WireEvent>[];
  core.onCaptured(events.add);
  return (core: core, http: http, src: _Source(), events: events);
}

List<Map<String, dynamic>> _named(List<WireEvent> events, String name) =>
    [for (final e in events) if (e['event'] == name) Map<String, dynamic>.from(e['properties'] as Map)];

/// RFC 8017 7.1.2 decoding (the server's side), to check the encoding is reversible.
List<int> _oaepDecode(List<int> em) {
  const h = 32;
  expect(em[0], 0);
  final maskedSeed = em.sublist(1, 1 + h), maskedDb = em.sublist(1 + h);
  final seedMask = mgf1Sha256(maskedDb, h);
  final seed = [for (var i = 0; i < h; i++) maskedSeed[i] ^ seedMask[i]];
  final dbMask = mgf1Sha256(seed, maskedDb.length);
  final db = [for (var i = 0; i < maskedDb.length; i++) maskedDb[i] ^ dbMask[i]];
  expect(db.sublist(0, h), sha256.convert(const <int>[]).bytes);
  var i = h;
  while (db[i] == 0) {
    i++;
  }
  expect(db[i], 1);
  return db.sublist(i + 1);
}

// e = 1 with n = 2^2048 - 1 makes RSA the identity, so the whole pipeline can be decoded without a private key.
final _identityN = (BigInt.one << 2048) - BigInt.one;
String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');
final _identityKey = ExposureKey('k1', _b64url(bigIntToBytes(_identityN, 256)), 'AQ', '');

void main() {
  // P-M17
  test('screenMasked: exact, wildcard, case-insensitive, empty list', () {
    expect(ReplayPolicy.screenMasked('Checkout', ['Checkout']), isTrue);
    expect(ReplayPolicy.screenMasked('CheckoutDone', ['Checkout']), isFalse);
    expect(ReplayPolicy.screenMasked('PaymentPage', ['pay*']), isTrue);
    expect(ReplayPolicy.screenMasked('UserSettings', ['*settings']), isTrue);
    expect(ReplayPolicy.screenMasked('a-b-c', ['a*c']), isTrue);
    expect(ReplayPolicy.screenMasked('checkout', ['CHECKOUT']), isTrue);
    expect(ReplayPolicy.screenMasked('Home', ['pay*']), isFalse);
    expect(ReplayPolicy.screenMasked('Home', []), isFalse);
  });

  test('remote config parses the privacy keys; an incomplete key is off', () {
    final r = RemoteReplayConfig.parse(
        r'{"replay_mask_screens":["Pay*"],"replay_mask_text_patterns":["\\d+",7],"replay_exposure_fields":["card"],"replay_exposure_key":{"kid":"k1","n":"AQ","e":"AQAB","pkcs1":"AA=="}}')!;
    expect(r.maskScreens, ['Pay*']);
    expect(r.maskTextPatterns, [r'\d+']);
    expect(r.exposureFields, ['card']);
    expect(r.exposureKey?.kid, 'k1');
    expect(RemoteReplayConfig.parse('{"replay_exposure_key":{"kid":"k"}}')!.exposureKey, isNull);
  });

  test('a masked screen stars unmasked text and masks images (remote and local lists)', () async {
    final e = env();
    await ReplayRecorder(e.core, e.src, maskTextContent: false).tick();
    expect(e.http.chunks.single, contains('open 42'));

    final e2 = env();
    e2.http.configBody = '{"replay_mask_screens":["check*"]}';
    final r2 = ReplayRecorder(e2.core, e2.src, maskTextContent: false)..setScreen('Checkout');
    await r2.tick();
    expect(e2.http.chunks.single, isNot(contains('open 42')));
    expect(e2.http.chunks.single, isNot(contains('Order')));
    expect(e2.http.chunks.single, contains('data-lc-mask'));

    final e3 = env();
    final r3 = ReplayRecorder(e3.core, e3.src, maskTextContent: false, maskScreens: ['CHECKOUT'])..setScreen('Checkout');
    await r3.tick();
    expect(e3.http.chunks.single, isNot(contains('open 42')));
  });

  test('a masked screen paints every text and image in screenshots', () async {
    final e = env();
    final shots = _Shots();
    final r = ReplayRecorder(e.core, e.src, screenshots: shots, maskScreens: ['Pay*'])..setScreen('Payment');
    await r.tick();
    expect(shots.plans.single.unmask, isEmpty);
    expect(shots.plans.single.mask, hasLength(3));
  });

  // P-M46 text patterns
  test('maskPatterns stars matches, keeps whitespace, ignores invalid patterns', () {
    final res = compilePatterns([r'\d+', '(', r'\bsecret\b']);
    expect(res, hasLength(2));
    expect(maskPatterns('Order 1234 secret code', res), 'Order **** ****** code');
    expect(maskPatterns('card 4111 1111', compilePatterns([r'\d{4} \d{4}'])), 'card **** ****');
    expect(maskPatterns('nothing', res), 'nothing');
    expect(maskPatterns('abc', const []), 'abc');
  });

  test('patterns star shown wireframe text and paint matching nodes in screenshots', () async {
    final e = env();
    e.http.configBody = r'{"replay_mask_text_patterns":["\\d+"]}';
    await ReplayRecorder(e.core, e.src, maskTextContent: false).tick();
    expect(e.http.chunks.single, contains('Order ****'));
    expect(e.http.chunks.single, contains('open **'));

    final e2 = env();
    final shots = _Shots();
    await ReplayRecorder(e2.core, e2.src, screenshots: shots, maskTextPatterns: [r'\d+']).tick();
    expect(shots.plans.single.sensitive, hasLength(2));
  });

  // P-M46 dead swipe
  test('swipeDirection and deadSwipeDecision', () {
    expect(swipeDirection(-60, 10), 'left');
    expect(swipeDirection(60, -10), 'right');
    expect(swipeDirection(5, -70), 'up');
    expect(swipeDirection(5, 70), 'down');
    Map<String, dynamic>? d(String s, String a, String b, double dx, double dy, int now, [int? last]) =>
        deadSwipeDecision(
            screen: s, startScreen: 'A', startFingerprint: a, endFingerprint: b, dx: dx, dy: dy, nowMs: now, lastAt: last);
    expect(d('A', 'x', 'x', 0, -100.4, 5000), {r'$screen_name': 'A', r'$swipe_direction': 'up', r'$swipe_distance': 100});
    expect(d('A', 'x', 'x', 30, 30, 0), isNull, reason: 'under 48');
    expect(d('A', 'x', 'y', 100, 0, 0), isNull, reason: 'content moved');
    expect(d('B', 'x', 'x', 100, 0, 0), isNull, reason: 'navigated');
    expect(d('A', 'x', 'x', 100, 0, 1999, 0), isNull, reason: 'cooldown');
    expect(d('A', 'x', 'x', 100, 0, 2000, 0), isNotNull);
  });

  test('recorder captures a dead swipe only while recording, once per 2 s, not when content changed', () async {
    final e = env();
    final rec = ReplayRecorder(e.core, e.src, deadSwipeSettleDelay: Duration.zero)..setScreen('Feed');
    rec.swipeBegan();
    expect(await rec.swipeEnded(0, -200), isFalse, reason: 'no snapshot yet');
    await rec.tick();
    rec.swipeBegan();
    expect(await rec.swipeEnded(0, -200), isTrue);
    final p = _named(e.events, r'$dead_swipe').single;
    expect(p[r'$screen_name'], 'Feed');
    expect(p[r'$swipe_direction'], 'up');
    expect(p[r'$swipe_distance'], 200);
    rec.swipeBegan();
    expect(await rec.swipeEnded(100, 0), isFalse, reason: 'cooldown');
    _now += 3000;
    rec.swipeBegan();
    e.src.label = 'Order 99999';
    expect(await rec.swipeEnded(100, 0), isFalse, reason: 'the swipe changed the screen');
    final off = ReplayRecorder(e.core, e.src, captureDeadSwipes: false, deadSwipeSettleDelay: Duration.zero);
    await off.tick();
    off.swipeBegan();
    expect(await off.swipeEnded(100, 0), isFalse);
  });

  // P-L12
  test('OAEP encoding is reversible with a fixed seed; output is modulus length', () {
    final seed = List<int>.generate(32, (i) => i);
    final em = oaepEncode(utf8.encode('4111 1111'), 256, seed);
    expect(em, hasLength(256));
    expect(utf8.decode(_oaepDecode(em)), '4111 1111');
    expect(() => oaepEncode(List<int>.filled(191, 1), 256, seed), throwsArgumentError);
    final ct = rsaOaepEncrypt(utf8.encode('hi'), _identityN, BigInt.one, seed: seed);
    expect(ct, hasLength(256));
    expect(utf8.decode(_oaepDecode(ct)), 'hi');
  });

  test('modPow round trip with a tiny known key', () {
    final n = BigInt.from(3233), e = BigInt.from(17), d = BigInt.from(2753);
    final c = BigInt.from(65).modPow(e, n);
    expect(c, BigInt.from(2790));
    expect(c.modPow(d, n), BigInt.from(65));
    expect(bigIntToBytes(BigInt.from(0x0102), 4), [0, 0, 1, 2]);
    expect(bytesToBigInt([0, 1, 2]), BigInt.from(0x0102));
  });

  test('truncateUtf8 cuts on a code point boundary', () {
    final t = truncateUtf8('${'a' * 189}é');
    expect(t.bytes, hasLength(189));
    expect(t.truncated, isTrue);
    expect(truncateUtf8('short').truncated, isFalse);
    expect(encryptSensitive([1], const ExposureKey('k', '!!', 'AQ', '')), isNull);
  });

  test('captureSensitive needs the listed field, the key and consent; dedupes per session', () async {
    final e = env();
    e.http.configBody = jsonEncode({
      'replay_exposure_fields': ['card', 'iban'],
      'replay_exposure_key': {'kid': 'k1', 'n': _identityKey.n, 'e': _identityKey.e, 'pkcs1': ''},
    });
    final rec = ReplayRecorder(e.core, e.src)..setScreen('Pay');
    final client = Lucida(
        CoreConfig(apiKey: 'lc_pk_x', apiHost: 'https://ingest.test/', http: e.http, store: MemoryStore(), libName: 'lucida-dart', libVersion: '0.1.0'),
        appVersion: '1');
    expect(client.captureSensitive('card', '4111'), isFalse, reason: 'no recorder attached');
    expect(rec.captureSensitive('card', '4111'), isFalse, reason: 'remote config not loaded yet');
    await rec.tick();
    expect(rec.captureSensitive('card', '4111 1111'), isTrue);
    final p = _named(e.events, r'$sensitive_capture').single;
    expect(p[r'$exposure_field'], 'card');
    expect(p[r'$exposure_kid'], 'k1');
    expect(p[r'$screen_name'], 'Pay');
    expect(p.containsKey(r'$exposure_truncated'), isFalse);
    expect(utf8.decode(_oaepDecode(base64.decode(p[r'$exposure_ciphertext'] as String))), '4111 1111');
    expect(rec.captureSensitive('card', '4111 1111'), isFalse, reason: 'same value: not re-sent');
    expect(rec.captureSensitive('iban', 'x' * 300), isTrue);
    expect(_named(e.events, r'$sensitive_capture').last[r'$exposure_truncated'], isTrue);
    expect(rec.captureSensitive('email', 'a@b.c'), isFalse);
    e.core.setConsent({'replay': false});
    expect(rec.captureSensitive('card', 'other'), isFalse);
  });
}
