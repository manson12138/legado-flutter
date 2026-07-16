import Flutter
import UIKit

/// iOS 场景生命周期入口，沿用 Flutter 默认实现并保持业务状态由 Dart 管理。
final class SceneDelegate: FlutterSceneDelegate {
  /// 场景进入后台时同步暂停阅读器常亮，业务进度仍由 Dart WidgetsBindingObserver 保存。
  ///
  /// - Parameter scene: iOS 当前进入后台的场景。
  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    /// 当前 Flutter AppDelegate；类型不匹配时保持系统默认自动锁屏行为。
    let appDelegate = UIApplication.shared.delegate as? AppDelegate
    appDelegate?.pauseReaderKeepScreenOnForBackground(UIApplication.shared)
  }

  /// 场景恢复前台时按 Dart 最近请求重新应用阅读器常亮。
  ///
  /// - Parameter scene: iOS 当前恢复活动的场景。
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    /// 当前 Flutter AppDelegate；类型不匹配时保持系统默认自动锁屏行为。
    let appDelegate = UIApplication.shared.delegate as? AppDelegate
    appDelegate?.restoreReaderKeepScreenOnForForeground(UIApplication.shared)
  }

}
