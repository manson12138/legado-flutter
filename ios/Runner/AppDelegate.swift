import Flutter
import UIKit

@main
/// iOS 应用进程入口，只负责 Flutter 引擎生命周期和插件注册，不持有业务状态。
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// M08 阅读器平台通道；强引用保证 Flutter 引擎存活期间处理器持续有效。
  private var readerPlatformChannel: FlutterMethodChannel?

  /// 首次进入阅读器前系统的自动锁屏状态，退出时用于恢复。
  private var originalIdleTimerDisabled: Bool?

  /// Dart 阅读设置最近请求的常亮状态，前后台切换后据此恢复而不复制阅读业务。
  private var readerRequestedKeepScreenOn: Bool = false

  /// 首次进入阅读器前的屏幕亮度，退出或跟随系统时用于恢复。
  private var originalScreenBrightness: CGFloat?

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

  /// App 进入后台时临时恢复系统自动锁屏，避免后台保留阅读器窗口标志。
  ///
  /// - Parameter application: 当前 UIApplication 实例，仅用于读取和修改系统窗口能力。
  override func applicationDidEnterBackground(_ application: UIApplication) {
    pauseReaderKeepScreenOnForBackground(application)
    super.applicationDidEnterBackground(application)
  }

  /// App 回到前台时重新应用 Dart 最近请求的阅读常亮设置。
  ///
  /// - Parameter application: 当前 UIApplication 实例，仅用于恢复系统窗口能力。
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    restoreReaderKeepScreenOnForForeground(application)
  }

  /// Scene 生命周期进入后台时临时停用阅读常亮；重复调用保持幂等。
  ///
  /// - Parameter application: 当前 UIApplication 实例，仅用于修改自动锁屏能力。
  func pauseReaderKeepScreenOnForBackground(_ application: UIApplication) {
    if originalIdleTimerDisabled != nil {
      application.isIdleTimerDisabled = false
    }
  }

  /// Scene 生命周期恢复前台时重新应用 Dart 最近请求的阅读常亮值。
  ///
  /// - Parameter application: 当前 UIApplication 实例，仅用于恢复自动锁屏能力。
  func restoreReaderKeepScreenOnForForeground(_ application: UIApplication) {
    if originalIdleTimerDisabled != nil {
      application.isIdleTimerDisabled = readerRequestedKeepScreenOn
    }
  }

  /// App 终止前恢复进入阅读器之前的系统自动锁屏状态。
  ///
  /// - Parameter application: 当前 UIApplication 实例，仅用于最终清理窗口能力。
  override func applicationWillTerminate(_ application: UIApplication) {
    restoreOriginalIdleTimerState(application)
    super.applicationWillTerminate(application)
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
        self?.setReaderBrightness(arguments)
        result(nil)
      case "setKeepScreenOn":
        self?.setReaderKeepScreenOn(enabled)
        result(nil)
      case "exitReader":
        self?.exitReaderWindow()
        result(nil)
      case "setBrightness":
        self?.setReaderBrightness(arguments)
        result(nil)
      case "getBatteryLevel":
        result(self?.readBatteryLevel())
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
    if originalScreenBrightness == nil {
      originalScreenBrightness = UIScreen.main.brightness
    }
    readerRequestedKeepScreenOn = enabled
    setReaderKeepScreenOn(enabled)
  }

  /// 阅读中按设置更新自动锁屏，不改写已经保存的原始状态。
  private func setReaderKeepScreenOn(_ enabled: Bool) {
    readerRequestedKeepScreenOn = enabled
    UIApplication.shared.isIdleTimerDisabled = enabled
  }

  /// 离开阅读器时恢复进入前的自动锁屏状态。
  private func exitReaderWindow() {
    restoreOriginalIdleTimerState(UIApplication.shared)
    restoreOriginalBrightness()
  }

  /// 阅读中按 Dart 设置更新屏幕亮度；跟随系统时恢复进入阅读器前亮度。
  ///
  /// - Parameter arguments: Dart 传入的亮度参数 Map。
  private func setReaderBrightness(_ arguments: [String: Any]?) {
    if originalScreenBrightness == nil {
      originalScreenBrightness = UIScreen.main.brightness
    }
    /// 是否跟随系统亮度；缺失时按系统亮度处理。
    let useSystemBrightness = arguments?["useSystemBrightness"] as? Bool ?? true
    if useSystemBrightness {
      restoreOriginalBrightness()
      return
    }
    /// Dart 传入的阅读亮度，范围由 Dart 层预先收窄。
    let brightness = arguments?["brightness"] as? Double ?? 0.5
    UIScreen.main.brightness = CGFloat(min(max(brightness, 0.05), 1.0))
  }

  /// 恢复进入阅读器之前的屏幕亮度。
  private func restoreOriginalBrightness() {
    guard let restoreValue = originalScreenBrightness else {
      return
    }
    UIScreen.main.brightness = restoreValue
    originalScreenBrightness = nil
  }

  /// 读取 iOS 当前电量百分比；不可用时返回 nil 交给 Dart 隐藏。
  private func readBatteryLevel() -> Int? {
    /// 当前设备对象，电量监控需要临时开启。
    let device = UIDevice.current
    /// 调用前的电量监控状态，读取后恢复。
    let originalMonitoringEnabled = device.isBatteryMonitoringEnabled
    device.isBatteryMonitoringEnabled = true
    defer {
      device.isBatteryMonitoringEnabled = originalMonitoringEnabled
    }
    if device.batteryState == .unknown || device.batteryLevel < 0 {
      return nil
    }
    return Int((device.batteryLevel * 100).rounded()).clamped(to: 0...100)
  }

  /// 将自动锁屏恢复到进入阅读器之前的状态，并清除本次阅读会话标记。
  ///
  /// - Parameter application: 需要恢复自动锁屏状态的 UIApplication 实例。
  private func restoreOriginalIdleTimerState(_ application: UIApplication) {
    guard let restoreValue = originalIdleTimerDisabled else {
      return
    }
    /// 阅读器进入前的原始自动锁屏状态。
    application.isIdleTimerDisabled = restoreValue
    originalIdleTimerDisabled = nil
    readerRequestedKeepScreenOn = false
  }
}

/// 为整数提供闭区间收窄，避免平台异常值越过 Dart UI 边界。
private extension Int {
  /// 将整数限制在给定闭区间内。
  func clamped(to range: ClosedRange<Int>) -> Int {
    return min(max(self, range.lowerBound), range.upperBound)
  }
}
