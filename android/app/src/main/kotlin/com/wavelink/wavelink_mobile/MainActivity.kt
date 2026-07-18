package com.wavelink.wavelink_mobile

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class MainActivity : FlutterActivity() {
    private val audioEngine = AudioEngine()
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 方法通道: Dart → Native
        MethodChannel(messenger, "wavelink/audio").setMethodCallHandler { call, result ->
            handleMethodCall(call.method, call.arguments, result)
        }

        // 事件通道: Native → Dart
        EventChannel(messenger, "wavelink/audio_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                    audioEngine.eventCallback = { event ->
                        when (event) {
                            "completed" -> sink.success("completed")
                            else -> sink.success(event)
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    audioEngine.eventCallback = null
                }
            }
        )
    }

    private fun handleMethodCall(method: String, arguments: Any?, result: Result) {
        when (method) {
            "play" -> {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any>
                val dataBytes = args?.get("pcmBytes") as? ByteArray
                val sampleRate = (args?.get("sampleRate") as? Number)?.toInt() ?: 44100
                val channels = (args?.get("channels") as? Number)?.toInt() ?: 2

                if (dataBytes == null) {
                    result.error("INVALID_ARGS", "play: missing pcmBytes", null)
                    return
                }
                val floatCount = dataBytes.size / 4
                val floats = FloatArray(floatCount)
                val bb = java.nio.ByteBuffer.wrap(dataBytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                bb.asFloatBuffer().get(floats)

                audioEngine.play(floats, sampleRate, channels)
                result.success(null)
            }

            "pause" -> {
                audioEngine.pause()
                result.success(null)
            }
            "resume" -> {
                audioEngine.resume()
                result.success(null)
            }
            "stop" -> {
                audioEngine.stop()
                result.success(null)
            }
            "seek" -> {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any>
                val posMs = (args?.get("positionMs") as? Number)?.toInt() ?: 0
                audioEngine.seek(posMs)
                result.success(null)
            }
            "isPlaying" -> result.success(audioEngine.isPlaying)
            else -> result.notImplemented()
        }
    }
}
