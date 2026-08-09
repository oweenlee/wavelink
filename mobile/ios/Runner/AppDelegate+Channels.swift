import Flutter
import UIKit
import AVFoundation
import MediaPlayer

// ── Flutter MethodChannel 处理 ────────────────────────────────
//
// AppDelegate 的通道注册与各 channel handler 实现：
// - wavelink/audio        播放控制 + 锁屏元数据 + bit-perfect 速率协商
// - wavelink/audio_events 远控/中断事件推流（remote:* 协议）
// - wavelink/file_picker  系统文件选择器
// - wavelink/media_store  MPMediaQuery 音乐库扫描

extension AppDelegate {
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
                let coverPath = args["coverPath"] as? String ?? ""
                audio.updateNowPlaying(title: title, artist: artist, album: album, duration: duration, filePath: filePath, coverPath: coverPath)
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
    /// 优先 passthrough 直通（不重编码保源质）；输出类型必须经兼容性校验
    /// （否则 setOutputFileType 抛 NSInvalidArgumentException 崩溃），
    /// 直通不可行时回退 M4A 转码（任意音频资产均兼容）。
    private func resolveLibraryAsset(urlString: String, result: @escaping FlutterResult) {
        guard let url = URL(string: urlString) else {
            result(nil)
            return
        }
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let base = String(url.absoluteString.hashValue & 0x7fffffff)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exported", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // 直通导出：输出类型必须在该 session 的兼容列表内，否则 setOutputFileType
            // 抛 NSInvalidArgumentException 崩溃。优先 URL 扩展名对应类型，否则取首个兼容类型。
            if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
                let compatible = (try? await session.compatibleFileTypes) ?? []
                let urlExt = url.pathExtension.lowercased()
                let preferred = self.outputFileType(forExt: urlExt.isEmpty ? "m4a" : urlExt)
                let finalType: AVFileType? = compatible.contains(preferred)
                    ? preferred
                    : compatible.first
                if let ft = finalType {
                    let dest = dir.appendingPathComponent("\(base).\(self.extForFileType(ft))")
                    if FileManager.default.fileExists(atPath: dest.path) {
                        await MainActor.run { result(dest.path) }
                        return
                    }
                    session.outputURL = dest
                    session.outputFileType = ft
                    await session.export()
                    if session.status == .completed {
                        await MainActor.run { result(dest.path) }
                        return
                    }
                }
            }

            // 直通不可行（类型不兼容/DRM 等）：回退 M4A 转码
            let m4aDest = dir.appendingPathComponent("\(base).m4a")
            if FileManager.default.fileExists(atPath: m4aDest.path) {
                await MainActor.run { result(m4aDest.path) }
                return
            }
            if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
                session.outputURL = m4aDest
                session.outputFileType = .m4a
                await session.export()
                if session.status == .completed {
                    await MainActor.run { result(m4aDest.path) }
                    return
                }
            }
            // 全部失败（如 Apple Music DRM 保护曲目）：返回 nil，Dart 侧提示无法播放
            await MainActor.run { result(nil) }
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

    /// AVFileType → 文件扩展名（dest 命名对齐实际容器类型用）
    private func extForFileType(_ type: AVFileType) -> String {
        switch type {
        case .mp3: return "mp3"
        case .m4a: return "m4a"
        case .caf: return "caf"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .mov: return "mov"
        case .mp4: return "mp4"
        default: return "m4a"
        }
    }

    // ── 文件选择器 ──

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

// ── 文件选择器回调 ──

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

// ── 音频事件流（remote:* 协议推到 Dart）──

extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        audio.setEventSink(events); return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? {
        audio.setEventSink(nil); return nil
    }
}
