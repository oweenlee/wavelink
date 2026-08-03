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
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * 流式音频引擎：与 iOS 一致，从 Rust 引擎 ringbuf 拉取 PCM。
 *
 * Dart 侧定期调用 [pushPcm] 推送交错立体声 float 数据，
 * 本类写入 AudioTrack 播放，数据不足时静默等待（underrun 由引擎缓冲吸收）。
 *
 * 音频焦点：播放时请求 AUDIOFOCUS_GAIN。焦点变化时：
 * - 永久丢失（其他音乐 app）→ 发 remote:pause，不自动恢复
 * - 瞬时丢失（来电/语音搜索 TTS）→ 发 remote:pause，焦点恢复后自动续播
 * - 可降音 → 本地 setVolume(0.3) 压低，不暂停引擎
 * - 拔耳机（ACTION_AUDIO_BECOMING_NOISY）→ 发 remote:pause，避免声音从扬声器爆出
 * 事件经 eventCallback 走与 iOS 锁屏命令同一套 remote:* 协议，Dart 统一处理。
 */
class AudioEngine(context: Context) {
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

    // 流式 PCM 队列（每项为交错立体声 float）
    private val pcmQueue = LinkedBlockingQueue<FloatArray>(512)

    // 已写入样本总数（交错），用于 positionMs
    @Volatile private var writtenSamples = 0L

    var eventCallback: ((String) -> Unit)? = null

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
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
        pcmQueue.clear()
        playing = true
        paused = false

        val channelMask = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO
                          else AudioFormat.CHANNEL_OUT_MONO
        val bufferSize = maxOf(
            AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_FLOAT),
            8192
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

        audioTrack?.play()

        writeThread = Thread {
            try {
                val chunk = FloatArray(4096)
                while (playing && !Thread.interrupted()) {
                    if (paused) {
                        try { Thread.sleep(50) } catch (_: InterruptedException) { break }
                        continue
                    }
                    // 阻塞取一块；超时无数据则回到循环顶部继续检查 playing
                    val block = pcmQueue.poll(200, TimeUnit.MILLISECONDS)
                        ?: continue
                    var off = 0
                    while (off < block.size && playing && !Thread.interrupted()) {
                        if (paused) {
                            try { Thread.sleep(50) } catch (_: InterruptedException) { break }
                            continue
                        }
                        val n = minOf(chunk.size, block.size - off)
                        System.arraycopy(block, off, chunk, 0, n)
                        audioTrack?.write(chunk, 0, n, AudioTrack.WRITE_BLOCKING)
                        writtenSamples += n
                        off += n
                    }
                }
            } catch (_: InterruptedException) {
                // stop() 中断了 sleep——安全退出
            }
        }
        writeThread?.start()
    }

    /** Dart 侧推送引擎输出的交错立体声 float 数据 */
    fun pushPcm(samples: FloatArray) {
        if (!playing || paused || samples.isEmpty()) return
        if (!pcmQueue.offer(samples)) {
            // 队列满时丢弃最旧的块，避免播放延迟不断累积
            pcmQueue.poll()
            pcmQueue.offer(samples)
        }
    }

    fun pause() {
        paused = true
        audioTrack?.pause()
    }

    fun resume() {
        requestAudioFocus()
        paused = false
        audioTrack?.play()
    }

    fun stop() {
        abandonAudioFocus()
        unregisterNoisyReceiver()
        playing = false
        writeThread?.interrupt()
        writeThread = null
        pcmQueue.clear()
        try { audioTrack?.stop() } catch (_: Exception) {}
        try { audioTrack?.release() } catch (_: Exception) {}
        audioTrack = null
        writtenSamples = 0
    }

    fun seek(positionMs: Int) {
        // 流式模式下位置由 Rust 引擎控制，此处只需清掉积压的旧 PCM，
        // 并把已写入样本计数器对齐到新位置（供 positionMs 未来被消费时不漂移）
        pcmQueue.clear()
        writtenSamples = positionMs.toLong() * sampleRate * channels / 1000
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            // 暂停态 seek 不应误启动 AudioTrack（避免空转的“已播放”状态）
            if (!paused) {
                audioTrack?.play()
            }
        } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "AudioEngine"
    }
}
