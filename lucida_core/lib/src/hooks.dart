import 'dart:math';

import 'ports.dart';
import 'queue.dart';

/// A `beforeSend` hook: return the (possibly amended) event, or null to drop it.
typedef BeforeSend = WireEvent? Function(WireEvent event);

/// Ordered hook chain. Each hook sees the previous hook's output; null stops the chain and drops the event.
/// A hook that throws is logged and skipped: the event continues unchanged (as it was before that hook).
class HookChain {
  HookChain(this._hooks, this._log);
  final List<BeforeSend> _hooks;
  final void Function(String) _log;

  WireEvent? run(WireEvent event) {
    var cur = event;
    for (final h in _hooks) {
      try {
        final next = h(cur);
        if (next == null) return null;
        cur = next;
      } catch (e) {
        _log('beforeSend hook threw, keeping event: $e');
      }
    }
    return cur;
  }
}

/// Keep roughly [rate] (0..1) of events and stamp survivors with `$sample_rate`. Compose it with your own filter hook.
BeforeSend sampleHook(double rate, {double Function()? random}) {
  final rnd = random ?? Random().nextDouble;
  return (e) {
    if (rate >= 1) return e;
    if (rate <= 0 || rnd() >= rate) return null;
    return {
      ...e,
      'properties': <String, dynamic>{...?(e['properties'] as Map?)?.cast<String, dynamic>(), '\$sample_rate': rate},
    };
  };
}

enum PersonProfiles { always, identifiedOnly, never }

const _identifiedKey = 'lc_person_identified';
const _alwaysProcessed = {'\$identify', '\$create_alias', '\$groupidentify'};

/// `personProfiles` state: identifiedOnly flips to processing on the first identify/alias/group/person-property write.
class PersonMode {
  PersonMode(this._s, this.mode) : _identified = _s.get(_identifiedKey) == '1';
  final KeyValueStore _s;
  final PersonProfiles mode;
  bool _identified;

  bool get blocksPersonWrites => mode == PersonProfiles.never;

  void markIdentified() {
    if (mode == PersonProfiles.identifiedOnly && !_identified) {
      _identified = true;
      _s.set(_identifiedKey, '1');
    }
  }

  /// True when an event of this name should carry `$process_person_profile: false`.
  bool personless(String event) => switch (mode) {
        PersonProfiles.always => false,
        PersonProfiles.never => !_alwaysProcessed.contains(event),
        PersonProfiles.identifiedOnly => !_identified && !_alwaysProcessed.contains(event),
      };

  void reset() {
    _identified = false;
    _s.remove(_identifiedKey);
  }
}
