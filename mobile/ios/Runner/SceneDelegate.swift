import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        // 与启动屏/BrandSplash 主色 #0A0A0A 对齐，避免 Flutter 首帧前的白/灰闪屏
        window?.backgroundColor = UIColor(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0, alpha: 1)
        if let controller = window?.rootViewController as? FlutterViewController,
           let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.registerChannels(with: controller.binaryMessenger)
        }
    }
}
