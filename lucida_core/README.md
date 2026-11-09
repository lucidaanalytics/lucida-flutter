# lucida_core

Pure-Dart core of the [Lucida](https://lucidace.com) SDK: a persistent capture queue (batching, gzip, retry), identity, sessions, consent, feature flags (local evaluation and `POST /v1/flags`), lifecycle events, screen views and the session replay pipeline. No Flutter dependency; Flutter apps use [`lucida_flutter`](https://pub.dev/packages/lucida_flutter).

```dart
import 'package:lucida_core/lucida_core.dart';
import 'package:lucida_core/lucida_io.dart';

final lucida = Lucida(
  CoreConfig(apiKey: 'lc_pk_...', apiHost: 'https://capture.lucidace.com', http: IoHttp(),
      store: MemoryStore(), libName: 'my-app', libVersion: '1.0.0'),
  appVersion: '1.2.3',
);
await lucida.start();
lucida.capture('signed_up', {'plan': 'pro'});
```

Docs: <https://lucidace.com/help>. Source: <https://github.com/lucidaanalytics/lucida-flutter>. License: Apache-2.0.
