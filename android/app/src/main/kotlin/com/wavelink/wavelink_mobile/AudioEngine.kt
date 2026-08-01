package com.wavelink.wavelink_mobile

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * 流式音频引擎：与 iOS 一致，从 Rust 引擎 ringbuf 拉取 PCM。
 *
 * Dart 侧定期调用 [pushPcm] 推送交错立体声 float 数据，
 * 本类写入 AudioTrack 播放，数据不足时静默等待（underrun 由引擎缓冲吸收）。
 */
class AudioEngine {
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

    val isPlaying: Boolean get() = playing
    val positionMs: Int get() {
        if (sampleRate <= 0 || channels <= 0) return 0
        val framesPerMs = (sampleRate * channels) / 1000.0
        return (writtenSamples / framesPerMs).toInt()
    }

    fun start(rate: Int, ch: Int) {
        stop()
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
            val chunk = FloatArray(4096)
            while (playing && !Thread.interrupted()) {
                if (paused) {
                    Thread.sleep(50)
                    continue
                }
                // 阻塞取一块；超时无数据则回到循环顶部继续检查 playing
                val block = pcmQueue.poll(200, TimeUnit.MILLISECONDS)
                    ?: continue
                var off = 0
                while (off < block.size && playing && !Thread.interrupted()) {
                    if (paused) {
                        Thread.sleep(50)
                        continue
                    }
                    val n = minOf(chunk.size, block.size - off)
                    System.arraycopy(block, off, chunk, 0, n)
                    audioTrack?.write(chunk, 0, n, AudioTrack.WRITE_BLOCKING)
                    writtenSamples += n
                    off += n
                }
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
        paused = false
        audioTrack?.play()
    }

    fun stop() {
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
        // 流式模式下位置由 Rust 引擎控制，此处只需清掉积压的旧 PCM
        pcmQueue.clear()
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.play()
        } catch (_: Exception) {}
    }
}
