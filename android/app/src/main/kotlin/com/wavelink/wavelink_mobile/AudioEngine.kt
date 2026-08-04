package com.wavelink.wavelink_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.util.Log
import kotlin.concurrent.thread

/**
 * 流式音频引擎：与 iOS 一致，从 Rust 引擎 ringbuf 直读 PCM。
 *
 * 不再由 Dart 定时推送（旧架构 40ms Timer + FRB + MethodChannel 三重 hop，
 * 后台被节流即 underrun）。改为本类原生 writeThread 通过 JNI 直读 Rust ringbuf
 * （`nativeFillInterleaved`，与 iOS AVAudioSourceNode 同一条 HeadlessOutput 通路），
 * 写入 AudioTrack。数据不足时静默等待（underrun 由引擎缓冲吸收）。
 *
 * 音频焦点：播放时请求 AUDIOFOCUS_GAIN。焦点变化时：
 * - 永久丢失（其他音乐 app）→ 发 remote:pause，不自动恢复
 * - 瞬时丢失（来电/语音搜索 TTS）→ 发 remote:pause，焦点恢复后自动续播
 * - 可降音 → 本地 setVolume(0.3) 压低，不暂停引擎
 * - 拔耳机（ACTION_AUDIO_BECOMING_NOISY）→ 发 remote:pause，避免声音从扬声器爆出
 * 事件经 eventCallback 走与 iOS 锁屏命令同一套 remote:* 协议，Dart 统一处理。
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

    private var audioTrack: AudioTrack? = null
    private var sampleRate: Int = 44100
    private var channels: Int = 2
    @Volatile private var playing = false
    @Volatile private var paused = false
    private var writeThread: Thread? = null

    // 已写入样本总数（交错），用于 positionMs
    @Volatile private var writtenSamples = 0L

    var eventCallback: ((String) -> Unit)? = null

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        Log.i("WaveLinkDiag", "音频焦点变化: $focusChange")
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 恢复音量（若之前 duck）；若因瞬时焦点丢失而暂停，则恢复播放
                audioTrack?.setVolume(1.0f)
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
                // 可降音：本地压低音量，不暂停引擎
                audioTrack?.setVolume(0.3f)
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
                .setWillPauseWhenDucked(false) // duck 由本地 setVolume 处理
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
    val positionMs: Int get() {
        if (sampleRate <= 0 || channels <= 0) return 0
        val framesPerMs = (sampleRate * channels) / 1000.0
        return (writtenSamples / framesPerMs).toInt()
    }

    fun start(rate: Int, ch: Int) {
        stop()
        requestAudioFocus()
        registerNoisyReceiver()
        sampleRate = rate
        channels = ch
        writtenSamples = 0
        playing = true
        paused = false

        val channelMask = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO
                          else AudioFormat.CHANNEL_OUT_MONO
        // 缓冲 ~200ms：泵按帧供给且偶有空读间隙，旧 ~21ms 小缓冲必欠载爆音
        val bufferSize = maxOf(
            AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_FLOAT),
            sampleRate * channels * 4 / 5 // float=4B，200ms
        )

        audioTrack = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(sampleRate)
                .setChannelMask(channelMask)
                .build(),
            bufferSize,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )

        // 播放门控：让 Rust 侧 ringbuf 开始产出（false 时 fill 直接返回 0）
        nativeSetPlaying(true)

        // 原生泵线程：JNI 直读 Rust ringbuf → AudioTrack
        writeThread = thread(name = "WaveLinkPump") {
            // 泵线程进音频调度组，避免被 MIUI 等调度策略饿死
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            val chunk = FloatArray(4096 * channels)
            // 预缓冲：开播前先往 AudioTrack 填 ~120ms，避免起播瞬间空窗
            // （ringbuf 从零开始填，直接开播会在前几百 ms 内反复欠载）
            var prefill = 0
            val prefillTarget = sampleRate * channels * 120 / 1000 // 样本数
            val deadline = System.currentTimeMillis() + 600
            while (playing && !Thread.interrupted() &&
                   prefill < prefillTarget && System.currentTimeMillis() < deadline) {
                val frames = nativeFillInterleaved(chunk, 4096)
                if (frames <= 0) {
                    try { Thread.sleep(5) } catch (_: InterruptedException) { break }
                    continue
                }
                val n = frames * channels
                val w = audioTrack?.write(chunk, 0, n, AudioTrack.WRITE_NON_BLOCKING) ?: 0
                if (w > 0) {
                    prefill += w
                    writtenSamples += w
                }
            }
            audioTrack?.play()

            while (playing && !Thread.interrupted()) {
                if (paused) {
                    try { Thread.sleep(50) } catch (_: InterruptedException) { break }
                    continue
                }
                val frames = nativeFillInterleaved(chunk, 4096)
                if (frames <= 0) {
                    // 门控关闭或 ringbuf 空：短睡眠再试（5ms，200ms 缓冲足以吸收）
                    try { Thread.sleep(5) } catch (_: InterruptedException) { break }
                    continue
                }
                val n = frames * channels
                val written = audioTrack?.write(
                    chunk, 0, n, AudioTrack.WRITE_BLOCKING
                ) ?: 0
                if (written > 0) writtenSamples += written
            }
        }
    }

    fun pause() {
        Log.i("WaveLinkDiag", "AudioEngine.pause()")
        paused = true
        nativeSetPlaying(false)
        audioTrack?.pause()
    }

    fun resume() {
        requestAudioFocus()
        // 清掉暂停前积压（与 iOS 一致），防恢复时先播旧声（磁带滑）
        nativeClearRingbuf()
        paused = false
        nativeSetPlaying(true)
        audioTrack?.play()
    }

    fun stop() {
        abandonAudioFocus()
        unregisterNoisyReceiver()
        playing = false
        nativeSetPlaying(false)
        writeThread?.interrupt()
        writeThread = null
        try { audioTrack?.stop() } catch (_: Exception) {}
        try { audioTrack?.release() } catch (_: Exception) {}
        audioTrack = null
        writtenSamples = 0
    }

    fun seek(positionMs: Int) {
        // 清掉 Rust ringbuf 积压（seek 时引擎本会 swap_consumer 换新 ringbuf，
        // 这里再兜底一次），并把已写入样本计数器对齐到新位置，供 positionMs 不漂移。
        nativeClearRingbuf()
        writtenSamples = positionMs.toLong() * sampleRate * channels / 1000
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            // 暂停态 seek 不应误启动 AudioTrack（避免空转的"已播放"状态）
            if (!paused) {
                audioTrack?.play()
            }
        } catch (_: Exception) {}
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

        // ── JNI 直读 Rust ringbuf（与 iOS 同一 HeadlessOutput 通路）──

        /// 拉取最多 maxFrames 帧交错立体声 PCM 填入 out，返回实际帧数
        @JvmStatic
        private external fun nativeFillInterleaved(out: FloatArray, maxFrames: Int): Int

        /// 播放门控：play/resume 设 true，pause/stop 设 false
        @JvmStatic
        private external fun nativeSetPlaying(playing: Boolean)

        /// 清空 ringbuf 积压
        @JvmStatic
        private external fun nativeClearRingbuf()

        /// 注册音频线程提权钩子到 audio-core
        @JvmStatic
        private external fun nativeRegisterElevateHook()
    }
}
