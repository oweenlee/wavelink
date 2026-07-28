package com.wavelink.wavelink_mobile

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

class MainActivity : FlutterActivity() {
    private val audioEngine = AudioEngine()
    private var eventSink: EventChannel.EventSink? = null
    private var filePickerResult: Result? = null

    private val filePickerLauncher = registerForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        val paths = mutableListOf<String>()
        for (uri in uris) {
            copyToAppStorage(uri)?.let { paths.add(it) }
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {}
        }
        filePickerResult?.success(paths)
        filePickerResult = null
    }

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

        // 文件选择器通道
        MethodChannel(messenger, "wavelink/file_picker").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFiles" -> {
                    filePickerResult = result
                    filePickerLauncher.launch(arrayOf("audio/*"))
                }
                else -> result.notImplemented()
            }
        }
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

    /// 将选中文件复制到应用私有目录，确保 Rust 解码器可以访问
    private fun copyToAppStorage(uri: Uri): String? {
        try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val fileName = queryFileName(uri) ?: "unknown_${System.currentTimeMillis()}"
            val destDir = File(filesDir, "Imported")
            if (!destDir.exists()) destDir.mkdirs()
            val destFile = File(destDir, fileName)
            if (!destFile.exists()) {
                inputStream.use { input ->
                    destFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            }
            return destFile.absolutePath
        } catch (e: Exception) {
            return null
        }
    }

    private fun queryFileName(uri: Uri): String? {
        val cursor = contentResolver.query(uri, null, null, null, null)
        return cursor?.use {
            val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && it.moveToFirst()) it.getString(nameIndex) else null
        }
    }
}
