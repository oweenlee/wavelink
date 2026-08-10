import Flutter
import UIKit
import AVFoundation

// ── App Delegate ──────────────────────────────────────────────
//
// 职责：启动流程 + AVAudioSession 配置 + 系统音频通知监听
// （中断/路由变化/引擎配置变化）。
// 通道处理见 AppDelegate+Channels.swift，音频引擎/锁屏见 AudioOutputManager.swift。

@main
@objc class AppDelegate: FlutterAppDelegate {
    let audio = AudioOutputManager()

    /// 文件选择器完成回调（pickFiles 期间持有，选择完成后置空）
    var filePickerCompletion: FlutterResult?

    /// 音频中断开始前是否正在播放（用于中断结束后自动恢复）
    private var wasPlayingBeforeInterruption = false

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

    // ── 系统音频通知处理 ──

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
            NSLog("[Audio] interruption begin, wasPlaying=%@", audio.isPlaying ? "true" : "false")
            wasPlayingBeforeInterruption = audio.isPlaying
            // 引擎侧立即暂停（不走 Dart，中断时 Dart 可能被系统节流）
            wavelink_session_interruption_began()
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
                // 引擎侧恢复（与 began 对称）；随后的 remote:play 让 Dart 走统一
                // play 路径恢复全链路（开门控+UI 状态），重复 resume 幂等无害
                wavelink_session_interruption_ended()
                audio.sendEvent("remote:play")
            }
            audio.refreshNowPlaying()
        }
    }
}
