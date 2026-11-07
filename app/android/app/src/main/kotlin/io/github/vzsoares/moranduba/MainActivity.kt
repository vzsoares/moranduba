package io.github.vzsoares.moranduba

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moranduba/call_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    CallService.update(this, call.argument<Boolean>("sharing") == true)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, CallService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
