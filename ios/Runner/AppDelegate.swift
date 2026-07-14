import Flutter
import UIKit

@main
/// iOS 应用进程入口，只负责 Flutter 引擎生命周期和插件注册，不持有业务状态。
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// M08 阅读器平台通道；强引用保证 Flutter 引擎存活期间处理器持续有效。
  private var readerPlatformChannel: FlutterMethodChannel?

  /// 首次进入阅读器前系统的自动锁屏状态，退出时用于恢复。
  private var originalIdleTimerDisabled: Bool?

  /// 完成 iOS 宿主启动并把生命周期继续交给 FlutterAppDelegate。
  ///
  /// - Parameters:
  ///   - application: 当前 UIApplication 实例，仅在宿主启动阶段使用。
  ///   - launchOptions: iOS 提供的可选启动原因，本阶段不解析业务入口。
  /// - Returns: FlutterAppDelegate 对启动结果的判断。
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Flutter 隐式引擎创建后注册已声明插件，不在 Swift 中复制 Dart 业务逻辑。
  ///
  /// - Parameter engineBridge: Flutter 提供的引擎桥接对象，用于取得插件注册表。
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    /// 取得只服务 M08 窗口常亮能力的插件注册器。
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ReaderPlatformBridge")
    /// 与 Dart ReaderPlatformService 共用的 MethodChannel。
    let channel = FlutterMethodChannel(
      name: "io.legado.flutter/reader_platform",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      /// Dart 传入的参数对象。
      let arguments = call.arguments as? [String: Any]
      /// 缺失参数安全回退为关闭常亮。
      let enabled = arguments?["enabled"] as? Bool ?? false
      switch call.method {
      case "enterReader":
        self?.enterReaderWindow(enabled)
        result(nil)
      case "setKeepScreenOn":
        self?.setReaderKeepScreenOn(enabled)
        result(nil)
      case "exitReader":
        self?.exitReaderWindow()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    readerPlatformChannel = channel
  }

  /// 进入阅读器时记录原始自动锁屏状态，再应用本书配置。
  private func enterReaderWindow(_ enabled: Bool) {
    if originalIdleTimerDisabled == nil {
      originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
    }
    setReaderKeepScreenOn(enabled)
  }

  /// 阅读中按设置更新自动锁屏，不改写已经保存的原始状态。
  private func setReaderKeepScreenOn(_ enabled: Bool) {
    UIApplication.shared.isIdleTimerDisabled = enabled
  }

  /// 离开阅读器时恢复进入前的自动锁屏状态。
  private func exitReaderWindow() {
    guard let restoreValue = originalIdleTimerDisabled else {
      return
    }
    /// 阅读器进入前的原始自动锁屏状态。
    UIApplication.shared.isIdleTimerDisabled = restoreValue
    originalIdleTimerDisabled = nil
  }
}
