import Flutter
import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// `installInfo` -> `{platform: "ios", token}` (AAAttribution token, iOS 14.3+; token is nil when unavailable).
public class LucidaFlutterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "lucida_flutter/install", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(LucidaFlutterPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "installInfo" else { return result(FlutterMethodNotImplemented) }
        DispatchQueue.global(qos: .utility).async {
            var token: String?
            #if canImport(AdServices)
            if #available(iOS 14.3, *) { token = try? AAAttribution.attributionToken() }
            #endif
            DispatchQueue.main.async { result(["platform": "ios", "token": token as Any]) }
        }
    }
}
