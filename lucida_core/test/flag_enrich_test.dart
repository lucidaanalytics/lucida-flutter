import 'package:lucida_core/lucida_core.dart';
import 'package:test/test.dart';

import 'core_test.dart' show make;

Map<String, dynamic> flag(String key, int pct) => {
      'key': key,
      'type': 'boolean',
      'active': true,
      'salt': 's',
      'aggregation': {'kind': 'person'},
      'conditions': [
        {'rollout_pct': pct}
      ],
    };

void main() {
  test('events carry flag values; the caller and \$snapshot are left alone', () async {
    final t = make();
    final f = Flags(t.core, definitions: [flag('on', 100), flag('off', 0)]);
    await f.reload();
    final e = t.core.capture('clicked', {'\$feature/on': 'mine'})!;
    final p = e['properties'] as Map;
    expect(p['\$feature/on'], 'mine');
    expect(p['\$feature/off'], false);
    expect(p['\$active_feature_flags'], ['on']);
    final snap = t.core.capture('\$snapshot')!['properties'] as Map;
    expect(snap.containsKey('\$active_feature_flags'), isFalse);
  });

  test('sendFeatureFlags: false leaves events alone', () async {
    final t = make();
    final f = Flags(t.core, definitions: [flag('on', 100)], options: const FlagOptions(sendFeatureFlags: false));
    await f.reload();
    expect((t.core.capture('clicked')!['properties'] as Map).containsKey('\$active_feature_flags'), isFalse);
  });

  test('flagEventProps is empty without flags', () {
    expect(flagEventProps({}), isEmpty);
  });
}
