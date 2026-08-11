import Flutter
import UIKit
import AVFoundation
import MediaPlayer

// ── Audio Output Manager ─────────────────────────────────────

/// iOS 音频输出与锁屏控制管理器。
///
/// 实际音频数据走 Rust ringbuf → AVAudioSourceNode 直出
/// （`audio_output_fill_buffer_stereo`），本类负责：
/// - AVAudioEngine / source node 生命周期与采样率重建
/// - MPRemoteCommandCenter 锁屏/控制中心命令（经 remote:* 事件到 Dart）
/// - MPNowPlayingInfoCenter 锁屏元数据与封面
class AudioOutputManager {
    let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    /// 仅主线程读写的播放标志（NowPlaying/resync 判断用）。
    /// 渲染线程用的是 Rust 侧原子门控（audio_output_set_playing），两者在四个控制点同步更新。
    private var isPlayingFlag = false
    /// 是否有活动曲目（播放中或暂停中，从 channel play/resume 到 stop）。
    /// 活动曲目期间绝不改变 source node/引擎速率：引擎对当前曲目的重采样
    /// 目标在开播时固定，中途改速率声明会造成产出/声明失配（变慢/变调）。
    /// 速率对齐留到下一曲开播时自然完成（bit-perfect 路径或引擎 SRC 兑底）。
    private var hasActiveTrack = false
    private var eventSink: FlutterEventSink?
    /// source node 当前生效的采样率（路由变化时据此判断是否需重建）
    var currentSourceRate: Double = 0

    // 当前曲目元数据
    private var nowTitle = ""
    private var nowArtist = ""
    private var nowAlbum = ""
    private var nowDuration: Double = 0
    private var nowPosition: Double = 0
    // 缓存当前曲封面：每次进度刷新都会重建 nowPlayingInfo，
    // 不缓存的话 artwork 会被不带图的 refresh 覆盖丢失
    private var lastCover: UIImage?
    /// 缓存的锁屏 artwork（随封面重建，refresh 时复用）
    private var lastArtwork: MPMediaItemArtwork?

    init() {
        rebuildSourceNode(sampleRate: AVAudioSession.sharedInstance().sampleRate)
        setupRemoteCommands()
    }

    /// App 启动时 session 配置（category/activate）完成后调用：
    /// 存储属性 init 时 session 尚未配置，source node 用的是激活前速率，
    /// 此处以激活后的实际采样率重建，保证与传给 Rust 的硬件速率一致。
    func resyncToSessionRate() {
        rebuildSourceNode(sampleRate: AVAudioSession.sharedInstance().sampleRate)
    }

    /// 路由/中断变化后的采样率重同步入口（iOS 无独立的采样率变更通知，
    /// 速率变化随 routeChange / interruption 发生，故在这两个时机调用）。
    ///
    /// 硬件速率与 source node 一致时仅按需恢复停摆的 engine；不一致时
    /// 停 engine → 以新速率重建 source node → 恢复运行，并调用
    /// `engine_sync_output_rate` 把 Rust 引擎产出速率一并对齐，
    /// 避免 source node 格式与硬件失配造成杂音。
    func resyncToSessionRateIfNeeded() {
        let actual = AVAudioSession.sharedInstance().sampleRate
        if abs(actual - currentSourceRate) < 1.0 {
            // 速率未变：仅在“应播但 engine 已停摆”时恢复（如路由切换后）
            if isPlayingFlag, !engine.isRunning {
                NSLog("[Audio] resync: 速率未变，重启停摆的 engine")
                try? AVAudioSession.sharedInstance().setActive(true)
                engine.prepare()
                try? engine.start()
            }
            return
        }
        if hasActiveTrack {
            // 曲目活动中（播放/暂停）：保持 source node/引擎速率不变（两者仍互
            // 相对齐），只重启被系统停止的 engine；AVAudioEngine 会自动把节点
            // 格式 SRC 到新硬件速率。速率对齐留到下一曲开播。
            NSLog("[Audio] resync: 速率 %.0f → %.0f，曲目活动中，保持速率，engineRunning=%@",
                  currentSourceRate, actual, engine.isRunning ? "true" : "false")
            if isPlayingFlag, !engine.isRunning {
                try? AVAudioSession.sharedInstance().setActive(true)
                engine.prepare()
                try? engine.start()
            }
            return
        }
        // 无活动曲目：重建到新速率 + 对齐引擎速率
        NSLog("[Audio] resync: 速率 %.0f → %.0f，无活动曲目，重建 source node", currentSourceRate, actual)
        engine.stop()
        rebuildSourceNode(sampleRate: actual)
        engine_sync_output_rate(UInt32(actual))
    }

    /// 创建（或重建）source node 并连接到混音器。
    /// AVAudioSourceNode 的输出格式在连接时固定，故切换采样率需 detach 旧节点再以新格式重建。
    private func rebuildSourceNode(sampleRate: Double) {
        NSLog("[Audio] rebuildSourceNode: %.0f (playing=%@, engineRunning=%@)", sampleRate, isPlayingFlag ? "true" : "false", engine.isRunning ? "true" : "false")
        if let old = sourceNode {
            engine.detach(old)
        }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate,
                                channels: 2,
                                interleaved: false)!

        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftBuf = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightBuf = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            // 播放门控在 Rust 侧（audio_output_set_playing，无锁 AtomicBool）：
            // 未播放时 Rust 直接输出静音。回调不再捕获 self、不读任何 Swift 跨线程状态。
            audio_output_fill_buffer_stereo(leftBuf, rightBuf, UInt32(frameCount))
            return noErr
        }

        sourceNode = node
        currentSourceRate = sampleRate
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    /// 切换输出采样率（bit-perfect 协调）。
    /// 设置 AVAudioSession 偏好采样率并读回实际值，重建 source node 到该速率。
    /// 返回实际生效的采样率：请求未必被满足（内置输出常固定，外接 DAC 才会真切）。
    func setOutputRate(_ rate: Double) -> Double {
        let session = AVAudioSession.sharedInstance()
        NSLog("[Audio] setOutputRate: 请求 %.0f，当前 session %.0f，node %.0f", rate, session.sampleRate, currentSourceRate)
        // 目标速率与当前一致（容差内）时无需重建，避免无谓的 engine 停启。
        // 同采样率曲目连续播放是常见场景（如整张专辑），跳过重建也利于 gapless。
        if abs(session.sampleRate - rate) < 1.0 {
            return session.sampleRate
        }

        let shouldRun = engine.isRunning || isPlayingFlag
        engine.stop()

        try? session.setPreferredSampleRate(rate)
        let actual = session.sampleRate

        rebuildSourceNode(sampleRate: actual)

        if shouldRun {
            try? session.setActive(true)
            try? engine.start()
        }
        return actual
    }

    // ── 锁屏 / 控制中心 ──

    private func setupRemoteCommands() {
        let cmd = MPRemoteCommandCenter.shared()

        cmd.playCommand.addTarget { [weak self] _ in
            self?.sendEvent("remote:play")
            return .success
        }
        cmd.pauseCommand.addTarget { [weak self] _ in
            self?.sendEvent("remote:pause")
            return .success
        }
        cmd.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.sendEvent("remote:togglePlayPause")
            return .success
        }
        cmd.nextTrackCommand.addTarget { [weak self] _ in
            self?.sendEvent("remote:next")
            return .success
        }
        cmd.previousTrackCommand.addTarget { [weak self] _ in
            self?.sendEvent("remote:previous")
            return .success
        }
        cmd.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.sendEvent("remote:seek:\(e.positionTime)")
            return .success
        }
    }

    /// 更新锁屏显示信息（含封面图）
    /// coverPath 优先：Dart 侧已提取的封面图片文件，直接读图（兼容 ipod-library:// 等无法解析的路径）
    /// filePath 回退：音频文件路径，用 AVAsset 提取内嵌封面
    func updateNowPlaying(title: String, artist: String, album: String, duration: Double, filePath: String = "", coverPath: String = "") {
        nowTitle = title
        nowArtist = artist
        nowAlbum = album
        nowDuration = duration

        // 提取封面图：缓存图片优先，音频文件内嵌提取回退
        var coverImage: UIImage? = nil
        if !coverPath.isEmpty, FileManager.default.fileExists(atPath: coverPath) {
            coverImage = UIImage(contentsOfFile: coverPath)
        }
        if coverImage == nil && !filePath.isEmpty {
            let asset = AVAsset(url: URL(fileURLWithPath: filePath))
            let items = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: .commonIdentifierArtwork)
            if let data = items.first?.dataValue {
                coverImage = UIImage(data: data)
            }
        }
        // 新曲目刷新封面（可能为 nil，清掉上一曲的图）
        lastCover = coverImage
        // artwork 对象缓存复用，避免每次 refreshNowPlaying 重建
        lastArtwork = coverImage.map { img in
            MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        refreshNowPlaying()
    }

    /// 更新播放进度（事件驱动：play/pause/seek/切歌时推锚点，
    /// 锁屏进度由系统按 ElapsedPlaybackTime + PlaybackRate 自行插值）
    func updatePosition(_ positionMs: Double) {
        nowPosition = positionMs / 1000.0
        refreshNowPlaying()
    }

    /// 刷新锁屏显示（artwork 始终取自 lastCover，避免进度刷新把封面覆盖丢）
    func refreshNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = nowTitle
        info[MPMediaItemPropertyArtist] = nowArtist
        info[MPMediaItemPropertyAlbumTitle] = nowAlbum
        info[MPMediaItemPropertyPlaybackDuration] = nowDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nowPosition
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlayingFlag ? 1.0 : 0.0
        if let artwork = lastArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        NSLog("[Audio] refreshNowPlaying: rate=%@ title=%@ pos=%.1f",
              isPlayingFlag ? "1(播放)" : "0(暂停)", nowTitle, nowPosition)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 清空锁屏卡片（启动时清上次会话的残留：nowPlayingInfo 系统侧按
    /// bundle 缓存不随进程退出清除，残留会让锁屏停在旧的播放态）
    func clearNowPlaying() {
        NSLog("[Audio] clearNowPlaying")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // ── 播放控制 ──

    var isPlaying: Bool { isPlayingFlag }

    /// 幂等状态对账：Dart 周期性把权威播放态推下来，只刷锁屏按钮态。
    /// 不动音频门控/不重启 engine：偶发的 pause/resume 通道丢失在这自愈。
    func syncPlaying(_ playing: Bool) {
        guard playing != isPlayingFlag else { return }
        NSLog("[Audio] syncPlaying: 对账修正 %@ → %@",
              isPlayingFlag ? "播放" : "暂停", playing ? "播放" : "暂停")
        isPlayingFlag = playing
        if playing { hasActiveTrack = true }
        refreshNowPlaying()
    }

    func play() {
        NSLog("[Audio] play() nodeRate=%.0f sessionRate=%.0f", currentSourceRate, AVAudioSession.sharedInstance().sampleRate)
        isPlayingFlag = true
        hasActiveTrack = true
        audio_output_set_playing(true)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        refreshNowPlaying()
    }

    func pause() {
        isPlayingFlag = false
        audio_output_set_playing(false)
        // 停掉 engine 使音频会话与实际状态一致：仅写 PlaybackRate=0 不够，
        // engine 持续运行时系统媒体面板仍按"正在输出"判为播放态，锁屏
        // 停在 ⏸ 图标不跟随。各恢复路径（play/resume/resync/中断恢复）
        // 均有 !engine.isRunning 守卫，恢复时自动重启，无新增负担。
        engine.stop()
        refreshNowPlaying()
    }

    func resume() {
        isPlayingFlag = true
        hasActiveTrack = true
        audio_output_set_playing(true)
        audio_output_clear_ringbuf()
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        refreshNowPlaying()
    }

    func stop() {
        isPlayingFlag = false
        hasActiveTrack = false
        audio_output_set_playing(false)
        engine.stop() // 与 pause 同理：会话状态与实际对齐，锁屏按钮才跟随
        refreshNowPlaying()
    }

    // ── 事件通道 ──

    func setEventSink(_ sink: FlutterEventSink?) { eventSink = sink }

    func sendEvent(_ event: String) {
        eventSink?(event)
    }
}
