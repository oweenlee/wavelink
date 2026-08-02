package com.wavelink.wavelink_mobile

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

class MainActivity : FlutterActivity() {
    private val audioEngine = AudioEngine(this)
    private var eventSink: EventChannel.EventSink? = null
    private var filePickerResult: Result? = null

    // 权限请求
    private var permissionResult: Result? = null

    companion object {
        private const val FILE_PICK_REQUEST_CODE = 0x1001
        private const val MEDIA_PERMISSION_REQUEST_CODE = 0x1002
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
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "audio/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                    startActivityForResult(intent, FILE_PICK_REQUEST_CODE)
                }
                else -> result.notImplemented()
            }
        }

        // 系统音乐库通道（替代 on_audio_query）
        MethodChannel(messenger, "wavelink/media_store").setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermission" -> {
                    result.success(checkMediaPermission())
                }
                "requestPermission" -> {
                    permissionResult = result
                    requestMediaPermission()
                }
                "scanAll" -> {
                    val songs = scanMediaStore()
                    result.success(songs)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MEDIA_PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            permissionResult?.success(granted)
            permissionResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FILE_PICK_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data != null) {
                val uris = mutableListOf<Uri>()
                data.data?.let { uris.add(it) }
                data.clipData?.let { clip ->
                    for (i in 0 until clip.itemCount) {
                        clip.getItemAt(i).uri?.let { uris.add(it) }
                    }
                }
                val paths = uris.mapNotNull { copyToAppStorage(it) }
                for (uri in uris) {
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                    } catch (_: Exception) {}
                }
                filePickerResult?.success(paths)
            } else {
                // 用户取消选择或出错 → 返回空列表，避免 Dart 侧 future 永久挂起
                filePickerResult?.success(emptyList<String>())
            }
            filePickerResult = null
        }
    }

    private fun checkMediaPermission(): Boolean {
        val perm = if (android.os.Build.VERSION.SDK_INT >= 33)
            android.Manifest.permission.READ_MEDIA_AUDIO
        else
            android.Manifest.permission.READ_EXTERNAL_STORAGE
        return ContextCompat.checkSelfPermission(this, perm) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestMediaPermission() {
        val perm = if (android.os.Build.VERSION.SDK_INT >= 33)
            android.Manifest.permission.READ_MEDIA_AUDIO
        else
            android.Manifest.permission.READ_EXTERNAL_STORAGE
        ActivityCompat.requestPermissions(this, arrayOf(perm), MEDIA_PERMISSION_REQUEST_CODE)
    }

    private fun scanMediaStore(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.AudioColumns._ID,
            MediaStore.Audio.AudioColumns.TITLE,
            MediaStore.Audio.AudioColumns.ARTIST,
            MediaStore.Audio.AudioColumns.ALBUM,
            MediaStore.Audio.AudioColumns.DURATION,
            MediaStore.Audio.AudioColumns.DATA,
            MediaStore.Audio.AudioColumns.ALBUM_ID,
        )
        val selection = "${MediaStore.Audio.AudioColumns.IS_MUSIC} != 0"
        val cursor = contentResolver.query(uri, projection, selection, null, null)
        cursor?.use { c ->
            val idIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns._ID)
            val titleIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns.TITLE)
            val artistIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns.ARTIST)
            val albumIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns.ALBUM)
            val durIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns.DURATION)
            val dataIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns.DATA)
            val albumIdIdx = c.getColumnIndex(MediaStore.Audio.AudioColumns.ALBUM_ID)
            while (c.moveToNext()) {
                val id = c.getLong(idIdx)
                // Android 10+ scoped storage 下 DATA 列不可直接读文件路径，
                // 统一通过 content:// URI 复制到 app 私有目录，保证 Rust 解码器可访问。
                val mediaUri = Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
                val path = copyToAppStorage(mediaUri, "ms_$id")
                if (path == null) continue
                songs.add(mapOf(
                    "id" to "ms_$id",
                    "title" to (if (titleIdx >= 0) c.getString(titleIdx) ?: "" else ""),
                    "artist" to (if (artistIdx >= 0) c.getString(artistIdx) ?: "" else ""),
                    "album" to (if (albumIdx >= 0) c.getString(albumIdx) ?: "" else ""),
                    "duration" to (if (durIdx >= 0) c.getLong(durIdx) else 0L),
                    "path" to path,
                ))
            }
        }
        return songs
    }

    private fun handleMethodCall(method: String, arguments: Any?, result: Result) {
        when (method) {
            "play" -> {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any>
                val sampleRate = (args?.get("sampleRate") as? Number)?.toInt() ?: 44100
                val channels = (args?.get("channels") as? Number)?.toInt() ?: 2

                // 流式播放：不再整体传 PCM，由 Dart 侧定时从 Rust 引擎 ringbuf 拉取推送
                audioEngine.start(sampleRate, channels)
                result.success(null)
            }

            "pushPcm" -> {
                @Suppress("UNCHECKED_CAST")
                val args = arguments as? Map<String, Any>
                val samples = (args?.get("samples") as? FloatArray) ?: FloatArray(0)
                audioEngine.pushPcm(samples)
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
    /// [fallbackName]：文件名，缺省时从 content URI 查询 DISPLAY_NAME
    private fun copyToAppStorage(uri: Uri, fallbackName: String? = null): String? {
        try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val fileName = queryFileName(uri) ?: fallbackName
                ?: "unknown_${System.currentTimeMillis()}"
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
