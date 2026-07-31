import Flutter
import Security
import UIKit

@main
/// iOS 应用进程入口，只负责 Flutter 引擎生命周期和插件注册，不持有业务状态。
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// M08 阅读器平台通道；强引用保证 Flutter 引擎存活期间处理器持续有效。
  private var readerPlatformChannel: FlutterMethodChannel?

  /// 登录与注册密码加密通道；强引用保证 Flutter 引擎存活期间处理器持续有效。
  private var passwordEncryptionChannel: FlutterMethodChannel?

  /// 当前 iOS 安装包版本名称和构建号查询通道。
  private var appPackageInfoChannel: FlutterMethodChannel?

  /// P1-05 下载后台通道；iOS 只提供有限后台执行窗口，不承诺无限持续下载。
  private var downloadBackgroundChannel: FlutterMethodChannel?

  /// 当前有限后台下载任务标识；`.invalid` 表示没有活动窗口。
  private var downloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid

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
    endDownloadBackgroundTask(application)
    super.applicationWillTerminate(application)
  }

  /// Flutter 隐式引擎创建后注册已声明插件，不在 Swift 中复制 Dart 业务逻辑。
  ///
  /// - Parameter engineBridge: Flutter 提供的引擎桥接对象，用于取得插件注册表。
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerAppPackageInfoChannel(engineBridge)
    registerPasswordEncryptionChannel(engineBridge)
    /// 取得只服务 M08 窗口常亮能力的插件注册器；Xcode 26 下该 API 返回可空值。
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "ReaderPlatformBridge"
    ) else {
      return
    }
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
    registerDownloadBackgroundChannel(engineBridge)
  }

  /// 注册实际安装包版本通道；只读取 Info.plist，不持有监听器或业务状态。
  ///
  /// - Parameter engineBridge: Flutter 隐式引擎桥，用于取得独立插件注册器。
  private func registerAppPackageInfoChannel(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AppPackageInfoBridge"
    ) else {
      return
    }
    /// 与 Dart AppPackageInfoService 共用的平台通道。
    let channel = FlutterMethodChannel(
      name: "io.legado.flutter/app_package_info",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getPackageInfo" else {
        result(FlutterMethodNotImplemented)
        return
      }
      /// Xcode 从 Flutter versionName 写入的当前安装包语义版本。
      let versionName = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String
      /// Xcode 从 Flutter build number 写入的当前安装包构建号。
      let versionCode = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String
      result([
        "versionName": versionName ?? "",
        "versionCode": versionCode ?? "",
      ])
    }
    appPackageInfoChannel = channel
  }

  /// 注册使用系统 SecKey 的 RSA-OAEP-SHA256 加密通道；不记录明文、公钥或密文。
  private func registerPasswordEncryptionChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "PasswordEncryptionBridge"
    ) else {
      return
    }
    /// 与 Dart PasswordEncryptionService 共用的方法通道。
    let channel = FlutterMethodChannel(
      name: "io.legado.flutter/password_encryption",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "encryptRsaOaepSha256" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let publicKeyPem = arguments["publicKeyPem"] as? String,
            let plaintext = arguments["plaintext"] as? String,
            !publicKeyPem.isEmpty,
            !plaintext.isEmpty,
            let self else {
        result(FlutterError(code: "PASSWORD_ENCRYPTION_FAILED", message: "密码加密准备失败", details: nil))
        return
      }
      self.encryptPassword(publicKeyPem: publicKeyPem, plaintext: plaintext, result: result)
    }
    passwordEncryptionChannel = channel
  }

  /// 使用 SecKey 的 OAEP-SHA256 算法加密 UTF-8 密码并返回 Base64 密文。
  private func encryptPassword(publicKeyPem: String, plaintext: String, result: @escaping FlutterResult) {
    guard let derData = decodePublicKeyPem(publicKeyPem),
          let plaintextData = plaintext.data(using: .utf8),
          let publicKey = createRsaPublicKey(derData) else {
      result(FlutterError(code: "PASSWORD_ENCRYPTION_FAILED", message: "密码加密准备失败", details: nil))
      return
    }
    /// iOS 系统定义的 OAEP-SHA256 同时固定主摘要和 MGF1 摘要为 SHA-256。
    let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
    guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
      result(FlutterError(code: "PASSWORD_ENCRYPTION_FAILED", message: "密码加密准备失败", details: nil))
      return
    }
    /// Security 框架只返回受控错误，不把底层异常详情暴露给 Dart。
    var securityError: Unmanaged<CFError>?
    guard let encryptedData = SecKeyCreateEncryptedData(publicKey, algorithm, plaintextData as CFData, &securityError) else {
      result(FlutterError(code: "PASSWORD_ENCRYPTION_FAILED", message: "密码加密准备失败", details: nil))
      return
    }
    result((encryptedData as Data).base64EncodedString())
  }

  /// 解码后端下发的 PEM SubjectPublicKeyInfo 公钥数据。
  private func decodePublicKeyPem(_ publicKeyPem: String) -> Data? {
    /// 移除 PEM 包装和所有换行、空格。
    let base64Text = publicKeyPem
      .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    return Data(base64Encoded: base64Text)
  }

  /// 从服务端 SPKI 或已经是 PKCS#1 的 DER 数据创建系统 RSA 公钥。
  private func createRsaPublicKey(_ derData: Data) -> SecKey? {
    /// Security 框架可能按系统版本接受 SPKI 或 PKCS#1，因此先保留原始数据再安全回退。
    let candidates = [derData, extractPkcs1PublicKey(from: derData)].compactMap { $0 }
    for candidate in candidates {
      /// 声明导入数据是 RSA 公钥，不持久化到 Keychain。
      let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
      ]
      /// Security 框架的受控错误不向调用方泄露。
      var securityError: Unmanaged<CFError>?
      if let key = SecKeyCreateWithData(candidate as CFData, attributes as CFDictionary, &securityError) {
        return key
      }
    }
    return nil
  }

  /// 从 X.509 SubjectPublicKeyInfo 中提取内嵌的 PKCS#1 RSA 公钥，以兼容 Security 导入边界。
  private func extractPkcs1PublicKey(from subjectPublicKeyInfo: Data) -> Data? {
    /// DER 字节视图仅在当前函数栈内短暂存在。
    let bytes = [UInt8](subjectPublicKeyInfo)
    var index = 0
    guard let sequenceEnd = readDerElement(tag: 0x30, bytes: bytes, index: &index),
          let algorithmEnd = readDerElement(tag: 0x30, bytes: bytes, index: &index),
          algorithmEnd <= sequenceEnd else {
      return nil
    }
    index = algorithmEnd
    guard let bitStringEnd = readDerElement(tag: 0x03, bytes: bytes, index: &index),
          index < bitStringEnd,
          bytes[index] == 0x00 else {
      return nil
    }
    index += 1
    return Data(bytes[index..<bitStringEnd])
  }

  /// 读取单个 DER TLV 元素并返回内容结束位置；遇到越界或非 DER 长度立即失败。
  private func readDerElement(tag: UInt8, bytes: [UInt8], index: inout Int) -> Int? {
    guard index < bytes.count, bytes[index] == tag else {
      return nil
    }
    index += 1
    guard index < bytes.count else {
      return nil
    }
    /// DER 短长度或长长度编码的首字节。
    let firstLengthByte = bytes[index]
    index += 1
    var length = 0
    if firstLengthByte & 0x80 == 0 {
      length = Int(firstLengthByte)
    } else {
      /// 长长度后的长度字节数。
      let lengthByteCount = Int(firstLengthByte & 0x7f)
      guard lengthByteCount > 0, lengthByteCount <= 4, index + lengthByteCount <= bytes.count else {
        return nil
      }
      for _ in 0..<lengthByteCount {
        length = (length << 8) | Int(bytes[index])
        index += 1
      }
    }
    guard length >= 0, index + length <= bytes.count else {
      return nil
    }
    return index + length
  }

  /// 注册离线下载后台通道；系统只授予有限执行时间，过期后队列由下次前台启动续传。
  ///
  /// - Parameter engineBridge: Flutter 隐式引擎桥，用于取得独立插件注册器。
  private func registerDownloadBackgroundChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "DownloadBackgroundBridge"
    ) else {
      return
    }
    /// 与 Dart DownloadBackgroundService 共用的平台通道。
    let channel = FlutterMethodChannel(
      name: "io.legado.flutter/download_background",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startOrUpdate":
        self?.beginDownloadBackgroundTaskIfNeeded(UIApplication.shared)
        result(nil)
      case "stop":
        self?.endDownloadBackgroundTask(UIApplication.shared)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    downloadBackgroundChannel = channel
  }

  /// 在首次存在等待或运行任务时申请一次系统有限后台执行窗口。
  ///
  /// - Parameter application: 当前 UIApplication，用于申请后台任务标识。
  private func beginDownloadBackgroundTaskIfNeeded(_ application: UIApplication) {
    if downloadBackgroundTask != .invalid {
      return
    }
    downloadBackgroundTask = application.beginBackgroundTask(
      withName: "LegadoOfflineDownload"
    ) { [weak self] in
      self?.endDownloadBackgroundTask(application)
    }
  }

  /// 队列结束或系统后台时间到期时释放有限后台任务。
  ///
  /// - Parameter application: 当前 UIApplication，用于结束后台任务。
  private func endDownloadBackgroundTask(_ application: UIApplication) {
    if downloadBackgroundTask == .invalid {
      return
    }
    /// 需要交还给系统的后台任务标识。
    let task = downloadBackgroundTask
    downloadBackgroundTask = .invalid
    application.endBackgroundTask(task)
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
    return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
