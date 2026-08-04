package com.wavelink.wavelink_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * 前台播放服务：解决锁屏控制缺失 + 后台播放不可用两个高优问题。
 *
 * - MediaSession：锁屏 / 通知栏 / 蓝牙 / 系统媒体面板的播放控制与元数据展示，
 *   命令经 [remoteCallback] 走与 iOS 相同的 remote:* 协议到 Dart。
 * - 前台服务（mediaPlayback 类型）：进程在后台不被回收，播放不中断。
 * - 常驻 MediaStyle 通知：上一首 / 播放暂停 / 下一首按钮。
 *
 * 生命周期：MainActivity 在 play/resume 时 startForegroundService；Dart 的 stop
 * 只作切歌前 reset（置暂停态），不销毁服务——销毁会导致 MediaSession/通知每首歌
 * 重建、锁屏卡片闪断且播放状态竞态丢失。真正停止走通知 ACTION_STOP。
 */
class PlaybackService : Service() {

    companion object {
        private const val TAG = "PlaybackService"
        private const val CHANNEL_ID = "playback"
        private const val NOTIF_ID = 1001

        const val ACTION_PLAY_PAUSE = "com.wavelink.wavelink_mobile.PLAY_PAUSE"
        const val ACTION_NEXT = "com.wavelink.wavelink_mobile.NEXT"
        const val ACTION_PREV = "com.wavelink.wavelink_mobile.PREV"
        const val ACTION_STOP = "com.wavelink.wavelink_mobile.STOP"

        /** start() 携带的期望播放状态（消除服务创建完成前 setPlaying 丢失的竞态） */
        const val EXTRA_PLAYING = "com.wavelink.wavelink_mobile.EXTRA_PLAYING"

        @Volatile
        var instance: PlaybackService? = null

        /** MediaSession 发出的命令 → Dart（MainActivity 绑定） */
        @Volatile
        var remoteCallback: ((String) -> Unit)? = null

        fun start(context: Context, playing: Boolean) {
            val intent = Intent(context, PlaybackService::class.java)
                .putExtra(EXTRA_PLAYING, playing)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }

    private var mediaSession: MediaSession? = null
    private var notificationManager: NotificationManager? = null
    private var lastCoverPath: String? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
        mediaSession = MediaSession(this, "WaveLink").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    Log.i(TAG, "MediaSession onPlay")
                    remoteCallback?.invoke("remote:play")
                }

                override fun onPause() {
                    Log.i(TAG, "MediaSession onPause")
                    remoteCallback?.invoke("remote:pause")
                }

                override fun onStop() {
                    Log.i(TAG, "MediaSession onStop")
                    remoteCallback?.invoke("remote:pause")
                }

                override fun onSkipToNext() {
                    remoteCallback?.invoke("remote:next")
                }

                override fun onSkipToPrevious() {
                    remoteCallback?.invoke("remote:previous")
                }

                override fun onSeekTo(pos: Long) {
                    remoteCallback?.invoke("remote:seek:${pos / 1000.0}")
                }
            })
            // MediaSession.setActive(true) 由 MainActivity 在 play 后驱动（本处先激活，
            // 确保通知 MediaStyle 的 token 有效；无会话时锁屏/通知栏仍能展示）。
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY_PAUSE -> {
                Log.i(TAG, "通知按钮 PLAY_PAUSE")
                remoteCallback?.invoke("remote:togglePlayPause")
            }
            ACTION_NEXT -> remoteCallback?.invoke("remote:next")
            ACTION_PREV -> remoteCallback?.invoke("remote:previous")
            ACTION_STOP -> {
                // 先通知 Dart 暂停，再停服务；否则服务死了但 Dart/Rust 还在播，
                // 后台进程随时被杀，音频会无声消失
                remoteCallback?.invoke("remote:pause")
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                // Dart play/resume 驱动（首次启动或服务已运行时刷新）：
                // 播放状态经 intent 传入并在建通知前落定——旧实现依赖
                // instance?.setPlaying(true)，但服务 onCreate 前 instance 为 null，
                // 状态丢失导致通知/锁屏停在“播放”图标，与播放页不同步。
                if (intent?.hasExtra(EXTRA_PLAYING) == true) {
                    isPlaying = intent.getBooleanExtra(EXTRA_PLAYING, false)
                }
            }
        }
        // 立即把播放状态写入 MediaSession（锁屏/系统媒体面板），不等 Dart 250ms tick
        mediaSession?.let { updatePosition(lastPositionMs, isPlaying) }
        // 进前台 + 发常驻通知（首次进入时系统要求 5s 内调用，否则抛 ForegroundServiceDidNotStartInTimeException）
        startForegroundCompat(buildNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── MediaSession 元数据 / 播放状态 ──

    fun updateMetadata(title: String, artist: String, album: String, durationSec: Double, coverPath: String?, coverImagePath: String? = null) {
        this.title = title
        this.artist = artist
        lastCoverPath = coverImagePath ?: coverPath
        val session = mediaSession ?: return
        val md = android.media.MediaMetadata.Builder()
            .putString(android.media.MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(android.media.MediaMetadata.METADATA_KEY_ARTIST, artist)
            .putString(android.media.MediaMetadata.METADATA_KEY_ALBUM, album)
            .putLong(
                android.media.MediaMetadata.METADATA_KEY_DURATION,
                durationSec.toLong() * 1000L
            )
            .apply {
                // 封面优先：Dart 侧已提取的封面图片文件直接解码（兼容 content:// 等
                // 无法 setDataSource 的路径）；失败再按音频文件提取内嵌封面（与 iOS 对齐）
                var bmp: Bitmap? = coverImagePath
                    ?.takeIf { java.io.File(it).exists() }
                    ?.let { BitmapFactory.decodeFile(it) }
                if (bmp == null) coverPath?.let { p ->
                    try {
                        val retriever = android.media.MediaMetadataRetriever()
                        retriever.setDataSource(p)
                        val bytes = retriever.embeddedPicture
                        retriever.release()
                        bmp = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    } catch (_: Exception) {}
                }
                bmp?.let {
                    // 缩到长边 ≤600，避免大封面占内存/拖慢锁屏渲染
                    val long = maxOf(it.width, it.height)
                    val scaled = if (long > 600) {
                        val scale = 600.0 / long
                        Bitmap.createScaledBitmap(
                            it, (it.width * scale).toInt(), (it.height * scale).toInt(), true
                        )
                    } else it
                    putBitmap(android.media.MediaMetadata.METADATA_KEY_ALBUM_ART, scaled)
                }
            }
            .build()
        session.setMetadata(md)
        // 元数据变化需重建通知以展示封面/标题
        instance?.let { it.updateNotification(buildNotification()) }
    }

    /** positionMs 由 Dart 侧进度轮询驱动，刷新锁屏进度条 */
    @Volatile private var lastPositionMs = 0.0

    fun updatePosition(positionMs: Double, isPlaying: Boolean) {
        lastPositionMs = positionMs
        val session = mediaSession ?: return
        val state = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SEEK_TO or
                    PlaybackState.ACTION_STOP
            )
            .setState(
                if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionMs.toLong(),
                1.0f
            )
            .build()
        session.setPlaybackState(state)
    }

    // ── 通知 ──

    private fun buildNotification(): Notification {
        val session = mediaSession
        val intent = Intent(this, MainActivity::class.java)
        val contentIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = Notification.Builder(this)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(contentIntent)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .addAction(prevAction())
            .addAction(playPauseAction())
            .addAction(nextAction())

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setChannelId(CHANNEL_ID)
        }
        return builder.build()
    }

    private fun action(icon: Int, title: String, actionName: String): Notification.Action {
        val intent = Intent(this, PlaybackService::class.java).setAction(actionName)
        val pi = PendingIntent.getService(
            this, actionName.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(icon, title, pi).build()
    }

    private fun prevAction() = action(android.R.drawable.ic_media_previous, "上一首", ACTION_PREV)

    private fun playPauseAction(): Notification.Action =
        if (isPlaying)
            action(android.R.drawable.ic_media_pause, "暂停", ACTION_PLAY_PAUSE)
        else
            action(android.R.drawable.ic_media_play, "播放", ACTION_PLAY_PAUSE)

    private fun nextAction() = action(android.R.drawable.ic_media_next, "下一首", ACTION_NEXT)

    private fun updateNotification(n: Notification) {
        try {
            notificationManager?.notify(NOTIF_ID, n)
        } catch (_: Exception) {}
    }

    // ── 前台 / 通知渠道 兼容 ──

    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID, "播放", NotificationManager.IMPORTANCE_LOW
        ).apply {
            setShowBadge(false)
            setSound(null, null)
        }
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager?.createNotificationChannel(channel)
    }

    // ── 当前曲目信息（通知展示用）──

    private var title: CharSequence = "WaveLink"
    private var artist: CharSequence = ""
    @Volatile private var isPlaying = false

    fun setPlaying(playing: Boolean) {
        isPlaying = playing
        mediaSession?.let { updatePosition(lastPositionMs, playing) }
        updateNotification(buildNotification())
    }
}
