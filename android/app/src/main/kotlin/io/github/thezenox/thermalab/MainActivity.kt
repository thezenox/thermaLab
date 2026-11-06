package io.github.thezenox.thermalab

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var encoder: VideoEncoder? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A live camera view: keep the screen on while the app is in front.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "t2s_thermal/video")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            encoder?.finish()
                            encoder = VideoEncoder(
                                call.argument<String>("path")!!,
                                call.argument<Int>("width")!!,
                                call.argument<Int>("height")!!,
                                call.argument<Int>("fps") ?: 15,
                            )
                            result.success(null)
                        }
                        "frame" -> {
                            encoder?.addFrame(call.arguments as ByteArray)
                            result.success(null)
                        }
                        "stop" -> {
                            val path = encoder?.finish()
                            encoder = null
                            result.success(path)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("video", e.message, null)
                }
            }
    }

    override fun onDestroy() {
        encoder?.finish()
        encoder = null
        super.onDestroy()
    }
}
