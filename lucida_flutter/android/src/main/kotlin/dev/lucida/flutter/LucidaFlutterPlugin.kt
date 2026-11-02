package dev.lucida.flutter

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** `installInfo` -> `{platform: "android", referrer, clickTs, beginTs}` from the Play Install Referrer (null on failure). */
class LucidaFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var ctx: Context? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "lucida_flutter/install").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        ctx = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "installInfo") return result.notImplemented()
        val c = ctx ?: return result.success(null)
        var replied = false
        fun reply(v: Map<String, Any?>?) {
            if (!replied) {
                replied = true
                result.success(v)
            }
        }
        try {
            val client = InstallReferrerClient.newBuilder(c).build()
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    try {
                        if (code == InstallReferrerClient.InstallReferrerResponse.OK) {
                            val r = client.installReferrer
                            reply(mapOf("platform" to "android", "referrer" to r.installReferrer,
                                "clickTs" to r.referrerClickTimestampSeconds, "beginTs" to r.installBeginTimestampSeconds))
                        } else reply(mapOf("platform" to "android"))
                    } catch (_: Throwable) { reply(mapOf("platform" to "android")) }
                    try { client.endConnection() } catch (_: Throwable) {}
                }

                override fun onInstallReferrerServiceDisconnected() = reply(null)
            })
        } catch (_: Throwable) { reply(null) }
    }
}
