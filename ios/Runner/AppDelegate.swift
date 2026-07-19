import Flutter
import UIKit
import AVFoundation

// ── Audio Output Manager ─────────────────────────────────────

class AudioOutputManager {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var isPlayingFlag = false
    private var eventSink: FlutterEventSink?

    init() {
        setupSourceNode()
    }

    private func setupSourceNode() {
        // 非交错格式：mixer 只接受这个格式
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 44100,
                                channels: 2,
                                interleaved: false)!

        sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftBuf = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightBuf = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            // 暂停时引擎持续运行（避免 AVAudioSourceNode 的渲染时钟跳变），
            // 但回调里直接填静音，不消费 ringbuf。
            if !self.isPlayingFlag {
                let n = Int(frameCount)
                for i in 0..<n { leftBuf[i] = 0; rightBuf[i] = 0 }
                return noErr
            }

            // Rust 从交错 ringbuf 读出并分别写入左右声道 buffer
            audio_output_fill_buffer_stereo(leftBuf, rightBuf, UInt32(frameCount))
            return noErr
        }

        if let source = sourceNode {
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: fmt)
        }
    }

    var isPlaying: Bool { isPlayingFlag }

    func play() {
        isPlayingFlag = true
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
    }

    func pause() {
        isPlayingFlag = false
        // 注意：不调用 engine.pause()。AVAudioSourceNode 在 engine.pause 后回调会
        // 完全停摆，但 Rust 解码线程仍在往 ringbuf 推数据；resume 时一次性把暂停期间
        // 积压的数据吐出 = "磁带滑"。这里让引擎持续运行、回调填静音即可。
    }

    func resume() {
        isPlayingFlag = true
        // 丢弃暂停期间 ringbuf 里积压的旧数据，恢复后无缝接上实时解码
        audio_output_clear_ringbuf()
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
    }

    func stop() {
        isPlayingFlag = false
        // 引擎持续运行，回调在 isPlayingFlag=false 时填静音；
        // 真正停止解码由 Rust 侧 stop_file_decoder 处理（Dart 层已调用）。
    }

    func setEventSink(_ sink: FlutterEventSink?) { eventSink = sink }
}

// ── App Delegate ──────────────────────────────────────────────

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let audio = AudioOutputManager()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            registerChannels(with: controller.binaryMessenger)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
    }

    private func handleAudio(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "play": audio.play(); result(nil)
        case "pause": audio.pause(); result(nil)
        case "resume": audio.resume(); result(nil)
        case "stop": audio.stop(); result(nil)
        default: result(FlutterMethodNotImplemented)
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
}

extension AppDelegate: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        let paths = urls.map { $0.path }
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
