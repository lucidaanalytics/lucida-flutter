import 'dart:convert';
import 'dart:io';

import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

final dir = '${Platform.environment['LUCIDA_TESTDATA'] ?? '../../../testdata'}/flags';

void main() {
  for (final name in ['vectors_basic', 'vectors', 'vectors_g10', 'vectors_sticky', 'vectors_ops']) {
    test('conformance $name', () {
      final j = jsonDecode(File('$dir/$name.json').readAsStringSync()) as Map<String, dynamic>;
      for (final h in (j['hash_vectors'] as List).cast<Map<String, dynamic>>()) {
        expect(hashInput(h['input'] as String), h['hash'], reason: h['input'] as String);
      }
      final flags = (j['flags'] as List).cast<Map<String, dynamic>>();
      var n = 0;
      for (final v in (j['vectors'] as List).cast<Map<String, dynamic>>()) {
        final got = evaluateAll(flags, Map<String, dynamic>.from(v['context'] as Map))[v['flag']]!;
        final want = v['expected'] as Map<String, dynamic>;
        expect(got['value'], want['value'], reason: v['name'] as String);
        expect(got['reason'], want['reason'], reason: v['name'] as String);
        expect(got['condition_index'], want['condition_index'], reason: v['name'] as String);
        expect(got['variant'], want['variant'], reason: v['name'] as String);
        expect(jsonEncode(got['payload']), jsonEncode(want['payload']), reason: v['name'] as String);
        n++;
      }
      expect(n, greaterThan(0));
    });
  }
}
