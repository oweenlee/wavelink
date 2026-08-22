import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Dart ↔ 原生桥：接收播放态（刷新 Dock 菜单标题），回传播放控制动作。
  private var dockChannel: FlutterMethodChannel?
  private var isPlaying = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard
      let window = mainFlutterWindow,
      let controller = window.contentViewController as? FlutterViewController
    else { return }
    dockChannel = FlutterMethodChannel(
      name: "wavelink/dock",
      binaryMessenger: controller.engine.binaryMessenger
    )
    dockChannel?.setMethodCallHandler { [weak self] call, _ in
      guard let self = self else { return }
      if call.method == "setPlaying", let playing = call.arguments as? Bool {
        self.isPlaying = playing
        // Dock 菜单在用户右键点击图标时才拉取（applicationDockMenu），
        // 无需主动刷新 UI。
      }
    }
  }

  /// 右键 Dock 图标弹出的菜单：播放/暂停 + 下一首（macOS 音乐 App 惯例）。
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    let toggle = NSMenuItem(
      title: isPlaying ? "暂停" : "播放",
      action: #selector(dockTogglePlay),
      keyEquivalent: ""
    )
    toggle.target = self
    menu.addItem(toggle)

    let next = NSMenuItem(
      title: "下一首",
      action: #selector(dockNext),
      keyEquivalent: ""
    )
    next.target = self
    menu.addItem(next)
    return menu
  }

  @objc private func dockTogglePlay() {
    dockChannel?.invokeMethod("togglePlay", arguments: nil)
  }

  @objc private func dockNext() {
    dockChannel?.invokeMethod("next", arguments: nil)
  }
}
