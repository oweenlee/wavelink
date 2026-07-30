import Flutter
import UIKit
import AVFoundation
import MediaPlayer

// ── Audio Output Manager ─────────────────────────────────────

class AudioOutputManager {
    let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var isPlayingFlag = false
    private var eventSink: FlutterEventSink?

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

    /// 创建（或重建）source node 并连接到混音器。
    /// AVAudioSourceNode 的输出格式在连接时固定，故切换采样率需 detach 旧节点再以新格式重建。
    private func rebuildSourceNode(sampleRate: Double) {
        if let old = sourceNode {
            engine.detach(old)
        }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate,
                                channels: 2,
                                interleaved: false)!

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftBuf = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightBuf = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            guard let self = self, self.isPlayingFlag else {
                let n = Int(frameCount)
                for i in 0..<n { leftBuf[i] = 0; rightBuf[i] = 0 }
                return noErr
            }

            audio_output_fill_buffer_stereo(leftBuf, rightBuf, UInt32(frameCount))
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    /// 切换输出采样率（bit-perfect 协调）。
    /// 设置 AVAudioSession 偏好采样率并读回实际值，重建 source node 到该速率。
    /// 返回实际生效的采样率：请求未必被满足（内置输出常固定，外接 DAC 才会真切）。
    func setOutputRate(_ rate: Double) -> Double {
        let session = AVAudioSession.sharedInstance()
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
        isPlayingFlag = true
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        refreshNowPlaying()
    }

    func pause() {
        isPlayingFlag = false
        refreshNowPlaying()
    }

    func resume() {
        isPlayingFlag = true
        audio_output_clear_ringbuf()
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        refreshNowPlaying()
    }

    func stop() {
        isPlayingFlag = false
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
        try? session.setActive(true)

        // 将硬件采样率传给 Rust，避免 48kHz 文件无谓重采样
        let hwRate = session.sampleRate
        set_hw_sample_rate(UInt32(hwRate))

        // 监听音频中断（电话/闹钟/快速前后台切换），中断结束时清空 ringbuf 避免噪声
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            registerChannels(with: controller.binaryMessenger)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let type = info[AVAudioSessionInterruptionTypeKey] as? UInt
        else { return }

        if type == AVAudioSession.InterruptionType.ended.rawValue {
            // 中断结束：清空 ringbuf 避免累积脏数据导致杂音
            audio_output_clear_ringbuf()
            // 确保 AudioUnit 恢复运行
            if !audio.engine.isRunning {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? audio.engine.start()
            }
            audio.refreshNowPlaying()
        }
    }

    private var filePickerCompletion: FlutterResult?

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
        case "play": audio.play(); result(nil)
        case "pause": audio.pause(); result(nil)
        case "resume": audio.resume(); result(nil)
        case "stop": audio.stop(); result(nil)
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
        default:
            result(FlutterMethodNotImplemented)
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
