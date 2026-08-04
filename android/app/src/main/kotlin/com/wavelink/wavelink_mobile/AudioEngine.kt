package com.wavelink.wavelink_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Android 音频引擎宿主。
 *
 * 自 v2 起音频输出由 Rust 引擎通过 Oboe/AAudio 直接驱动（engine_init 时打开
 * Exclusive/Shared 流，解码 → DSP → 回调线程直出设备），本类不再持有
 * AudioTrack，也不再运行 Kotlin 泵线程（WaveLinkPump 已移除）。
 *
 * 本类职责缩减为：
 * - 音频焦点管理（永久丢失/瞬时丢失/可降音）
 * - 拔耳机（ACTION_AUDIO_BECOMING_NOISY）处理
 * - 焦点事件经 eventCallback 走与 iOS 相同的 remote:* 协议到 Dart，
 *   Dart 统一调 Rust 引擎命令（play/pause/resume/seek）。
 */
class AudioEngine(private val context: Context) {
    private val appContext = context.applicationContext
    private val audioManager: AudioManager by lazy {
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    private var focusRequest: AudioFocusRequest? = null

    /// 拔耳机广播接收器：声音即将改走扬声器时暂停，避免外放爆出。
    /// 该 action 是系统保护广播（第三方无法伪造），注册生命周期跟随 start/stop。
    private var noisyReceiverRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            Log.i(TAG, "ACTION_AUDIO_BECOMING_NOISY（耳机拔出）→ 暂停")
            if (playing && !paused) {
                pausedByFocusLoss = false // 拔耳机不应自动续播
                eventCallback?.invoke("remote:pause")
            }
        }
    }

    private fun registerNoisyReceiver() {
        if (noisyReceiverRegistered) return
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) {
            appContext.registerReceiver(noisyReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            appContext.registerReceiver(noisyReceiver, filter)
        }
        noisyReceiverRegistered = true
    }

    private fun unregisterNoisyReceiver() {
        if (!noisyReceiverRegistered) return
        try { appContext.unregisterReceiver(noisyReceiver) } catch (_: Exception) {}
        noisyReceiverRegistered = false
    }

    /// 是否因瞬时焦点丢失而暂停（用于焦点恢复时判断是否自动续播）
    @Volatile private var pausedByFocusLoss = false

    @Volatile private var playing = false
    @Volatile private var paused = false

    var eventCallback: ((String) -> Unit)? = null

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        Log.i("WaveLinkDiag", "音频焦点变化: $focusChange")
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 恢复音量（若之前 duck）；若因瞬时焦点丢失而暂停，则恢复播放
                nativeSetVolume(1.0f)
                if (pausedByFocusLoss) {
                    pausedByFocusLoss = false
                    eventCallback?.invoke("remote:play")
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // 永久丢失（其他音乐 app 抢焦点）：暂停，不自动恢复，同步释放焦点
                pausedByFocusLoss = false
                abandonAudioFocus()
                eventCallback?.invoke("remote:pause")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 瞬时丢失（来电/语音搜索 TTS）：暂停，焦点恢复后自动续播
                pausedByFocusLoss = playing && !paused
                eventCallback?.invoke("remote:pause")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 可降音：压低引擎音量，不暂停
                nativeSetVolume(0.3f)
            }
        }
    }

    private fun requestAudioFocus() {
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(focusChangeListener)
                .setWillPauseWhenDucked(false) // duck 由引擎音量处理
                .build()
            focusRequest = req
            audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
    }

    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusChangeListener)
        }
        pausedByFocusLoss = false
    }

    val isPlaying: Boolean get() = playing
    /** 正在播放（含暂停=false；用于 MediaSession 状态上报） */
    val isActive: Boolean get() = playing && !paused

    /**
     * 启动音频宿主。音频输出流由 Rust 引擎在 engine_init 时通过 Oboe 打开，
     * 本方法只请求音频焦点 + 注册拔耳机监听，不再创建 AudioTrack / 泵线程。
     * [rate] / [ch] 参数保留仅为兼容旧调用方（引擎速率由 Rust 侧决定）。
     */
    fun start(rate: Int, ch: Int) {
        stop()
        requestAudioFocus()
        registerNoisyReceiver()
        playing = true
        paused = false
    }

    fun pause() {
        Log.i("WaveLinkDiag", "AudioEngine.pause()")
        paused = true
        // 引擎暂停由 Dart 侧调 Rust 命令完成（engine_pause）
    }

    fun resume() {
        requestAudioFocus()
        paused = false
        // 引擎恢复由 Dart 侧调 Rust 命令完成（engine_resume）
    }

    fun stop() {
        abandonAudioFocus()
        unregisterNoisyReceiver()
        playing = false
        paused = false
    }

    /**
     * seek 无需原生处理：Rust 引擎 seek 时会 swap_consumer 换新 ringbuf，
     * Oboe 回调自动读新缓冲，不存在旧 PCM 残留问题。
     */
    fun seek(positionMs: Int) {
        // no-op（Rust 侧已处理）
    }

    companion object {
        private const val TAG = "AudioEngine"

        init {
            // 确保 so 被 JVM 加载：Java_ 前缀的 JNI 符号才能经 dlsym 解析
            System.loadLibrary("rust_lib_wavelink_mobile")
            // 注册音频线程提权钩子（解码/consumer 线程启动时自动走
            // Process.setThreadPriority URGENT_AUDIO，否则生产侧会被调度饿死）
            nativeRegisterElevateHook()
        }

        /// 设置引擎音量（0~1，用于焦点 duck/恢复）
        @JvmStatic
        private external fun nativeSetVolume(volume: Float)

        /// 注册音频线程提权钩子到 audio-core
        @JvmStatic
        private external fun nativeRegisterElevateHook()
    }
}
