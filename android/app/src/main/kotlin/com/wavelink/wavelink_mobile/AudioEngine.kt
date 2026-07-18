package com.wavelink.wavelink_mobile

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper

class AudioEngine {
    private var audioTrack: AudioTrack? = null
    private var pcmBuffer: FloatArray = floatArrayOf()
    @Volatile var readIndex: Int = 0
    private var sampleRate: Int = 44100
    private var channels: Int = 2
    @Volatile private var playing = false
    @Volatile private var paused = false
    private var writeThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    var eventCallback: ((String) -> Unit)? = null

    val isPlaying: Boolean get() = playing
    val positionMs: Int get() {
        if (sampleRate <= 0 || channels <= 0) return 0
        val framesPerMs = (sampleRate * channels) / 1000.0
        return (readIndex / framesPerMs).toInt()
    }

    fun play(data: FloatArray, rate: Int, ch: Int) {
        stop()
        pcmBuffer = data
        sampleRate = rate
        channels = ch
        readIndex = 0
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
                val avail = pcmBuffer.size - readIndex
                if (avail <= 0) {
                    playing = false
                    mainHandler.post { eventCallback?.invoke("completed") }
                    break
                }
                val n = minOf(chunk.size, avail)
                System.arraycopy(pcmBuffer, readIndex, chunk, 0, n)
                readIndex += n
                audioTrack?.write(chunk, 0, n, AudioTrack.WRITE_BLOCKING)
            }
            // thread end
        }
        writeThread?.start()
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
        paused = false
        writeThread?.interrupt()
        writeThread = null
        try { audioTrack?.stop() } catch (_: Exception) {}
        try { audioTrack?.release() } catch (_: Exception) {}
        audioTrack = null
        readIndex = 0
    }

    fun seek(positionMs: Int) {
        val framesPerMs = (sampleRate * channels) / 1000.0
        readIndex = (positionMs * framesPerMs).toInt().coerceIn(0, pcmBuffer.size - 1)
        audioTrack?.pause()
        audioTrack?.flush()
        audioTrack?.play()
    }
}
