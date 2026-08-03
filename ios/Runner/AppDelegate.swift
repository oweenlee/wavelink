import Flutter
import UIKit
import AVFoundation
import MediaPlayer

// ── Audio Output Manager ─────────────────────────────────────

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
    /// filePath 传音频文件路径，iOS 用 AVAsset 提取内嵌封面
    func updateNowPlaying(title: String, artist: String, album: String, duration: Double, filePath: String = "") {
        nowTitle = title
        nowArtist = artist
        nowAlbum = album
        nowDuration = duration

        // 提取封面图
        var coverImage: UIImage? = nil
        if !filePath.isEmpty {
            let asset = AVAsset(url: URL(fileURLWithPath: filePath))
            let items = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: .commonIdentifierArtwork)
            if let data = items.first?.dataValue {
                coverImage = UIImage(data: data)
            }
        }
        refreshNowPlaying(cover: coverImage)
    }

    /// 更新播放进度
    func updatePosition(_ positionMs: Double) {
        nowPosition = positionMs / 1000.0
        refreshNowPlaying()
    }

    /// 刷新锁屏显示
    func refreshNowPlaying(cover: UIImage? = nil) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = nowTitle
        info[MPMediaItemPropertyArtist] = nowArtist
        info[MPMediaItemPropertyAlbumTitle] = nowAlbum
        info[MPMediaItemPropertyPlaybackDuration] = nowDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nowPosition
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlayingFlag ? 1.0 : 0.0
        if let image = cover {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // ── 播放控制 ──

    var isPlaying: Bool { isPlayingFlag }

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
        refreshNowPlaying()
    }

    // ── 事件通道 ──

    func setEventSink(_ sink: FlutterEventSink?) { eventSink = sink }

    func sendEvent(_ event: String) {
        eventSink?(event)
    }
}

// ── App Delegate ──────────────────────────────────────────────

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let audio = AudioOutputManager()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        // 音乐播放器不需要低延迟，加大 IO buffer 降低渲染回调频率，
        // 给 RT 线程（需连拿多把锁读 ringbuf）更多余裕，减少 underrun 杂音。
        try? session.setPreferredIOBufferDuration(0.02)
        try? session.setActive(true)

        // 将硬件采样率传给 Rust，避免 48kHz 文件无谓重采样
        let hwRate = session.sampleRate
        set_hw_sample_rate(UInt32(hwRate))

        // session 激活后速率可能与存储属性 init 时不同，以实际速率重建 source node
        audio.resyncToSessionRate()

        // 监听音频中断（电话/闹钟/快速前后台切换），中断结束时清空 ringbuf 避免噪声
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // 监听路由变化（耳机插拔/蓝牙/扬声器切换，以及 Spotlight 键盘音/听写麦克风
        // 等系统声音触发的硬件速率变化——iOS 无独立采样率通知，速率变化随路由变化发生）。
        // 路由/速率变化后若不重建 source node 并对齐引擎速率，格式失配 → 杂音。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // AVAudioEngine 在配置变化（路由/格式）时会被系统自动停止且不恢复，
        // 必须监听此通知并重建/重启，否则播放中静默死亡。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: audio.engine
        )

        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            registerChannels(with: controller.binaryMessenger)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    /// 路由变化（耳机插拔/蓝牙/系统声音触发的速率变化）：
    /// 检测硬件速率是否改变，变了则重建 source node + 对齐引擎速率（消除失配杂音），
    /// 未变则仅在引擎停摆时恢复。
    @objc private func handleRouteChange(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        let outs = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        NSLog("[Audio] routeChange → outputs=[%@], sessionRate=%.0f, nodeRate=%.0f, playing=%@, engineRunning=%@",
              outs, session.sampleRate, audio.currentSourceRate,
              audio.isPlaying ? "true" : "false", audio.engine.isRunning ? "true" : "false")
        audio.resyncToSessionRateIfNeeded()
    }

    /// AVAudioEngine 被系统因配置变化自动停止时触发：重建并按需恢复播放。
    @objc private func handleEngineConfigChange(_ notification: Notification) {
        NSLog("[Audio] AVAudioEngineConfigurationChange（引擎被系统停止，尝试恢复）")
        audio.resyncToSessionRateIfNeeded()
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let type = info[AVAudioSessionInterruptionTypeKey] as? UInt
        else { return }

        if type == AVAudioSession.InterruptionType.began.rawValue {
            // 中断开始（来电/闹钟/系统提示音）：记录中断前状态，通知 Dart 暂停引擎与 UI。
            NSLog("[Audio] interruption began, wasPlaying=%@", audio.isPlaying ? "true" : "false")
            wasPlayingBeforeInterruption = audio.isPlaying
            audio.pause()
            audio.sendEvent("remote:pause")
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            // 中断结束：中断期间硬件速率可能被改变（如通话音频），按需重同步采样率
            // （速率变了则重建 source node + 对齐引擎速率），否则恢复播放会因格式失配而杂音
            NSLog("[Audio] interruption ended, resume=%@", wasPlayingBeforeInterruption ? "true" : "false")
            audio.resyncToSessionRateIfNeeded()
            // 清空 ringbuf 避免累积脏数据
            audio_output_clear_ringbuf()
            // 确保 AudioUnit 恢复运行
            if !audio.engine.isRunning {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? audio.engine.start()
            }
            if wasPlayingBeforeInterruption {
                wasPlayingBeforeInterruption = false
                // began 时 Dart 已走 pause（引擎暂停+门控关），此处让 Dart 走统一
                // play 路径恢复全链路（resume 引擎+开门控+UI 状态），避免“中断后永久无声”
                audio.sendEvent("remote:play")
            }
            audio.refreshNowPlaying()
        }
    }

    private var filePickerCompletion: FlutterResult?

    /// 音频中断开始前是否正在播放（用于中断结束后自动恢复）
    private var wasPlayingBeforeInterruption = false

    func registerChannels(with messenger: FlutterBinaryMessenger) {
        let audioChannel = FlutterMethodChannel(name: "wavelink/audio", binaryMessenger: messenger)
        audioChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleAudio(call, result: result)
        }

        let eventChannel = FlutterEventChannel(name: "wavelink/audio_events", binaryMessenger: messenger)
        eventChannel.setStreamHandler(self)

        let filePickerChannel = FlutterMethodChannel(name: "wavelink/file_picker", binaryMessenger: messenger)
        filePickerChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleFilePicker(call, result: result)
        }

        let mediaStoreChannel = FlutterMethodChannel(name: "wavelink/media_store", binaryMessenger: messenger)
        mediaStoreChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleMediaStore(call, result: result)
        }
    }

    private func handleAudio(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "play": NSLog("[Audio] channel play"); audio.play(); result(nil)
        case "pause": NSLog("[Audio] channel pause"); audio.pause(); result(nil)
        case "resume": NSLog("[Audio] channel resume"); audio.resume(); result(nil)
        case "stop": NSLog("[Audio] channel stop"); audio.stop(); result(nil)
        case "updateMetadata":
            if let args = call.arguments as? [String: Any],
               let title = args["title"] as? String,
               let artist = args["artist"] as? String,
               let album = args["album"] as? String,
               let duration = args["duration"] as? Double {
                let filePath = args["filePath"] as? String ?? ""
                audio.updateNowPlaying(title: title, artist: artist, album: album, duration: duration, filePath: filePath)
            }
            result(nil)
        case "updatePosition":
            if let args = call.arguments as? [String: Any],
               let positionMs = args["positionMs"] as? Double {
                audio.updatePosition(positionMs)
            }
            result(nil)
        case "setOutputRate":
            guard let args = call.arguments as? [String: Any],
                  let rateNum = args["rate"] as? NSNumber
            else { result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil)); return }
            result(audio.setOutputRate(rateNum.doubleValue))
        case "resolveLibraryAsset":
            // 把 iPod library 歌曲（ipod-library:// URL，Rust 无法直接解码）
            // 导出为本地文件，返回可被 Rust 读取的绝对路径。
            guard let args = call.arguments as? [String: Any],
                  let urlString = args["url"] as? String
            else { result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil)); return }
            resolveLibraryAsset(urlString: urlString, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 导出 ipod-library:// 资产到 Documents/Exported/，已存在则直接复用。
    /// 使用 passthrough 预设避免重编码（源文件格式各异，输出扩展名从 URL 推断）。
    private func resolveLibraryAsset(urlString: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = URL(string: urlString) else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            // 缓存名：URL hash + 原始扩展名（m4a/mp3 等），同名直接复用
            let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
            let base = String(url.absoluteString.hashValue & 0x7fffffff)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exported", isDirectory: true)
            let dest = dir.appendingPathComponent("\(base).\(ext)")

            if FileManager.default.fileExists(atPath: dest.path) {
                DispatchQueue.main.async { result(dest.path) }
                return
            }

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            session.outputURL = dest
            session.outputFileType = self.outputFileType(forExt: ext)
            session.exportAsynchronously {
                let ok = session.status == .completed
                DispatchQueue.main.async {
                    result(ok ? dest.path : nil)
                }
            }
        }
    }

    private func outputFileType(forExt ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mp3": return .mp3
        case "m4a", "m4b", "aac": return .m4a
        case "caf": return .caf
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "mov": return .mov
        case "mp4": return .mp4
        case "opus", "ogg": return .m4a
        default: return .m4a
        }
    }

    private func handleFilePicker(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickFiles":
            guard let args = call.arguments as? [String: Any],
                  let exts = args["extensions"] as? [String],
                  let multiple = args["multiple"] as? Bool
            else { result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil)); return }
            filePickerCompletion = result
            presentPicker(extensions: exts, multiple: multiple)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func presentPicker(extensions: [String], multiple: Bool) {
        let picker = UIDocumentPickerViewController(
            documentTypes: ["public.audio"],
            in: .import
        )
        picker.allowsMultipleSelection = multiple
        picker.delegate = self

        let controller = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.rootViewController
        controller?.present(picker, animated: true)
    }

    // ── MediaStore (iOS MPMediaQuery 音乐库扫描) ──

    private func handleMediaStore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkPermission":
            let status = MPMediaLibrary.authorizationStatus()
            result(status == .authorized || status == .restricted)
        case "requestPermission":
            MPMediaLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    result(status == .authorized || status == .restricted)
                }
            }
        case "scanAll":
            scanMediaStore(result: result)
        case "getArtwork":
            guard let args = call.arguments as? [String: Any],
                  let pidStr = args["persistentId"] as? String,
                  let pid = UInt64(pidStr)
            else { result(nil); return }
            getArtwork(persistentId: pid, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func scanMediaStore(result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let query = MPMediaQuery.songs()
            var songs: [[String: Any]] = []

            guard let items = query.items else {
                DispatchQueue.main.async { result(songs) }
                return
            }

            for item in items {
                guard let assetURL = item.assetURL else { continue }

                let pid = item.persistentID
                let title = item.title ?? "Unknown"
                let artist = item.artist ?? "Unknown Artist"
                let album = item.albumTitle ?? "Unknown Album"
                let durationMs = Int(item.playbackDuration * 1000)

                songs.append([
                    "id": "ios_\(pid)",
                    "title": title,
                    "artist": artist,
                    "album": album,
                    "duration": durationMs,
                    "path": assetURL.absoluteString,
                ])
            }

            DispatchQueue.main.async { result(songs) }
        }
    }

    private func getArtwork(persistentId: UInt64, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let query = MPMediaQuery.songs()
            let filter = MPMediaPropertyPredicate(
                value: persistentId,
                forProperty: MPMediaItemPropertyPersistentID,
                comparisonType: .equalTo
            )
            query.addFilterPredicate(filter)

            guard let item = query.items?.first,
                  let artwork = item.artwork,
                  let image = artwork.image(at: artwork.bounds.size),
                  let data = image.jpegData(compressionQuality: 0.8)
            else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
        }
    }
}

extension AppDelegate: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        var paths: [String] = []
        for url in urls {
            // iCloud 文件需要安全作用域访问
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }

            // 复制到 Documents/Imported/ 下，避免 Inbox 路径问题
            let destName = url.lastPathComponent
            if let dest = try? FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Imported")
                .appendingPathComponent(destName) {
                // 避免覆盖已有文件
                if !FileManager.default.fileExists(atPath: dest.path) {
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        paths.append(dest.path)
                    } catch {
                        // 复制失败时 fallback 到原始路径
                        paths.append(url.path)
                    }
                } else {
                    paths.append(dest.path)
                }
            } else {
                paths.append(url.path)
            }
        }
        filePickerCompletion?(paths)
        filePickerCompletion = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        filePickerCompletion?([])
        filePickerCompletion = nil
    }
}

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        audio.setEventSink(events); return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? {
        audio.setEventSink(nil); return nil
    }
}
