# lucida_openfeature

OpenFeature provider for the Lucida Dart/Flutter SDK. Depends on `lucida_core` and the official
`openfeature_dart_server_sdk` 0.0.15 (Apache-2.0). Static-context paradigm: the context identifies one user, reads are synchronous over loaded flags.

```dart
final provider = LucidaFeatureProvider(lucida);
await provider.initializeContext({'targetingKey': 'u1', 'plan': 'pro', 'groups': {'org': 'acme'}});
final r = await provider.getBooleanFlag('new_nav', false);
provider.events.listen((e) => ...); // ready / configurationChanged / stale / error
provider.track('purchase', details: {'sku': 'a'}, value: 9.5); // -> capture, $value
```

- Context: `targetingKey` identifies; `groups` (type -> key) and `groupProperties` (type -> map) map to Lucida groups; every other attribute is a person property. `onContextChange(ctx)` re-identifies and reloads.
- Reasons follow `testdata/openfeature/reasons.json`; a `FlagOptions(fallbacks:)` value resolves with reason `DEFAULT` and no error code. Missing flag: `FLAG_NOT_FOUND`, wrong type: `TYPE_MISMATCH`.
- `lastMetadata` carries `lucidaReason`, `conditionIndex`, `requestId`, `evaluatedLocally` (the pinned SDK result type has no flagMetadata field).
- Core logic lives in `LucidaResolver` (SDK-independent), tested with `dart test`.
