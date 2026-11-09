# lucida_flutter

Flutter bindings for the [Lucida](https://lucidace.com) SDK over [`lucida_core`](https://pub.dev/packages/lucida_core): `LucidaProvider` (app lifecycle), `LucidaScreenObserver` (screen views), `PrefsStore` (SharedPreferences), install attribution on Android and iOS, the replay widget tree and screenshot boundary, and guide dialogs.

```dart
final lucida = createLucida(
  CoreConfig(apiKey: 'lc_pk_...', apiHost: 'https://capture.lucidace.com', http: IoHttp(),
      store: PrefsStore(await SharedPreferences.getInstance()), libName: 'lucida-flutter', libVersion: '0.1.0'),
  appVersion: '1.2.3',
);
await lucida.start();
runApp(LucidaProvider(client: lucida, child: MaterialApp(navigatorObservers: [LucidaScreenObserver(lucida)])));
```

Docs: <https://lucidace.com/help>. Source: <https://github.com/lucidaanalytics/lucida-flutter>. License: Apache-2.0.
