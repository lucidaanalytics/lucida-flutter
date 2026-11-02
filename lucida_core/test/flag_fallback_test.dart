import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

import 'core_test.dart' show FakeHttp, make;

const served =
    '{"flags":{"live":{"value":"b","variant":"b","reason":"condition_match","condition_index":2}},"request_id":"r9"}';

void main() {
  test('missing flag serves the fallback with reason fallback and no event', () async {
    final t = make(http: FakeHttp()..response = served);
    final f = Flags(t.core, options: const FlagOptions(fallbacks: {'gone': true}));
    await f.reload();
    expect(f.get('gone'), true);
    final d = f.getFeatureFlagDetails('gone')!;
    expect(d.reason, 'fallback');
    expect(d.value, true);
    await t.core.flush();
    expect(t.http.bodies.where((b) => b.contains('feature_flag_called')), isEmpty);
    expect(f.getFeatureFlagDetails('nofallback'), isNull);
    expect(f.get('nofallback'), false);
  });

  test('network failure serves the fallback and reports error status', () async {
    final t = make(http: FakeHttp()..statuses = [500]);
    final f = Flags(t.core, options: const FlagOptions(fallbacks: {'live': 'fb'}));
    final seen = <FlagsStatus>[];
    f.onFlagsStatus(seen.add);
    await f.reload();
    expect(f.get('live'), 'fb');
    expect(f.getFeatureFlagDetails('live')!.reason, 'fallback');
    expect(seen, [FlagsStatus.error]);
  });

  test('served flag keeps its real reason', () async {
    final t = make(http: FakeHttp()..response = served);
    final f = Flags(t.core, options: const FlagOptions(fallbacks: {'live': 'fb'}));
    await f.reload();
    final d = f.getFeatureFlagDetails('live')!;
    expect(d.value, 'b');
    expect(d.reason, 'condition_match');
    expect(d.conditionIndex, 2);
    expect(d.requestId, 'r9');
  });
}
