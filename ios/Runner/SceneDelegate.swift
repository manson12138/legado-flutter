import Flutter
import UIKit

/// iOS 场景生命周期入口，沿用 Flutter 默认实现并保持业务状态由 Dart 管理。
final class SceneDelegate: FlutterSceneDelegate {
  /// 场景冷启动连接完成后接收系统随连接参数交付的外部 TXT 文件。
  ///
  /// - Parameters:
  ///   - scene: iOS 当前创建的场景。
  ///   - session: 当前场景会话。
  ///   - connectionOptions: 可能包含冷启动外部文档 URL 的连接参数。
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )
    forwardExternalTxtOpenContexts(connectionOptions.urlContexts)
  }

  /// 场景已经存在时接收其他 App 新交付的外部 TXT 文件。
  ///
  /// - Parameters:
  ///   - scene: iOS 当前活动或即将恢复的场景。
  ///   - URLContexts: 系统交付的一组外部文件 URL 及其打开选项。
  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    super.scene(scene, openURLContexts: URLContexts)
    forwardExternalTxtOpenContexts(URLContexts)
  }

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

  /// 把 UIKit URL 上下文转换为无平台选项的文件 URL，再交给 AppDelegate 的有界队列。
  ///
  /// - Parameter contexts: 冷启动或热启动收到的系统 URL 上下文。
  private func forwardExternalTxtOpenContexts(
    _ contexts: Set<UIOpenURLContext>
  ) {
    if contexts.isEmpty {
      return
    }
    /// 当前 Flutter AppDelegate；类型不匹配时让系统保持默认处理。
    let appDelegate = UIApplication.shared.delegate as? AppDelegate
    /// 只在当前调用栈传递的 URL，不保留系统上下文对象。
    let urls = contexts.map(\.url)
    appDelegate?.handleExternalTxtOpenURLs(urls)
  }

}
