import Flutter
import Foundation

/// 接收 iOS 外部 TXT 文档 URL，并把安全作用域文件流式暂存为 Dart 可立即读取的 cache 副本。
///
/// 对应 Android `ExternalTxtOpenBridge.kt`。本桥只处理系统入口、受限复制和临时文件清理，
/// 不解析 TXT、不写数据库，也不长期保存文件提供方 URL。
final class ExternalTxtOpenBridge {
  /// 与 Dart `LocalBookStorage.maxBookBytes` 一致的单文件上限。
  private static let maxBookBytes: Int64 = 1024 * 1024 * 1024

  /// 单次进程会话允许等待的外部打开请求数，防止其他 App 无界投递。
  private static let maxPendingRequests = 4

  /// 超过一天仍未释放的临时副本会在下次桥初始化时清理。
  private static let staleFileAge: TimeInterval = 24 * 60 * 60

  /// 每次流式读取使用的固定缓冲区大小，不随 TXT 体积增长。
  private static let copyBufferBytes = 64 * 1024

  /// 外部 TXT 临时副本专用 cache 目录名。
  private static let cacheDirectoryName = "external_txt_open"

  /// 与 Dart `DefaultExternalLocalBookOpenService` 共用的方法通道。
  private let channel: FlutterMethodChannel

  /// 串行保存待处理 URL，并执行复制与清理，避免并发大文件放大磁盘压力。
  private let fileQueue = DispatchQueue(
    label: "com.contradiction.pagenest.external_txt_open.file"
  )

  /// 尚未被 Dart 消费的外部文件 URL，仅在 `fileQueue` 中访问。
  private var pendingURLs: [URL] = []

  /// 创建 iOS 外部 TXT 平台桥并注册稳定通道。
  ///
  /// - Parameter binaryMessenger: 当前 Flutter 引擎的消息总线。
  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.contradiction.pagenest/external_txt_open",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
    fileQueue.async { [weak self] in
      self?.deleteStaleFiles()
    }
  }

  /// 接收 Scene 冷启动或热启动交付的外部 URL，并按本次会话去重后加入有界队列。
  ///
  /// - Parameter urls: UIKit 交付的文件 URL；非文件 URL 会在消费时返回受控错误。
  func enqueue(_ urls: [URL]) {
    if urls.isEmpty {
      return
    }
    fileQueue.async { [weak self] in
      guard let self else {
        return
      }
      /// 本批次是否至少加入了一项新请求，用于避免无意义唤醒 Dart。
      var appendedRequest = false
      for url in urls {
        if self.pendingURLs.count >= Self.maxPendingRequests {
          break
        }
        /// URL 字符串只在当前进程内用于去重，不写日志或持久化。
        let identity = url.absoluteString
        if self.pendingURLs.contains(where: { $0.absoluteString == identity }) {
          continue
        }
        self.pendingURLs.append(url)
        appendedRequest = true
      }
      if appendedRequest {
        self.notifyRequestAvailable()
      }
    }
  }

  /// 处理 Dart 对下一请求消费或临时副本释放的调用。
  ///
  /// - Parameters:
  ///   - call: Dart 发起的方法调用。
  ///   - result: 必须在主线程完成的平台返回回调。
  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "consumeNext":
      consumeNext(result)
    case "releaseTemporary":
      releaseTemporary(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 从有界队列取得下一 URL，并在文件队列完成协调读取和临时复制。
  ///
  /// - Parameter result: 返回与 Android 桥一致的 path、name、size 和 token。
  private func consumeNext(_ result: @escaping FlutterResult) {
    fileQueue.async { [weak self] in
      guard let self else {
        Self.postResult(result, value: nil)
        return
      }
      /// 当前需要复制的请求；取出后即使失败也不会形成无限重试。
      guard !self.pendingURLs.isEmpty else {
        Self.postResult(result, value: nil)
        return
      }
      let url = self.pendingURLs.removeFirst()
      do {
        /// 返回给 Dart 的安全临时文件事实。
        let payload = try self.copyToTemporaryFile(url)
        Self.postResult(result, value: payload)
      } catch let error as ExternalTxtOpenBridgeError {
        Self.postError(result, error: error)
      } catch {
        Self.postError(
          result,
          error: ExternalTxtOpenBridgeError(
            code: "EXTERNAL_TXT_READ_FAILED",
            message: "无法读取外部 TXT 文件，请确认文件仍然存在且允许访问"
          )
        )
      }
    }
  }

  /// 按一次性 token 异步删除已经导入、失败或取消的外部临时副本。
  ///
  /// - Parameters:
  ///   - call: 包含随机 token 的 Dart 调用，不接受任意绝对路径。
  ///   - result: 清理完成回调；删除失败由过期清理兜底，不阻断导入页退出。
  private func releaseTemporary(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    /// Dart 返回的平台参数字典。
    let arguments = call.arguments as? [String: Any]
    /// 只能解析为本桥随机文件名的清理 token。
    let token = arguments?["token"] as? String
    guard let token, isSafeToken(token) else {
      result(nil)
      return
    }
    fileQueue.async { [weak self] in
      guard let self else {
        Self.postResult(result, value: nil)
        return
      }
      do {
        /// token 只能映射到专用 cache 目录的直接子文件。
        let temporaryURL = try self.cacheDirectory().appendingPathComponent(
          token,
          isDirectory: false
        )
        if self.fileManager.fileExists(atPath: temporaryURL.path) {
          try? self.fileManager.removeItem(at: temporaryURL)
        }
      } catch {
        // cache 目录暂时不可用时由下次桥初始化继续执行过期清理。
      }
      Self.postResult(result, value: nil)
    }
  }

  /// 校验外部文件并通过 `NSFileCoordinator` 生成完整的 cache 临时副本。
  ///
  /// - Parameter sourceURL: Scene 交付的安全作用域或 App Inbox 文件 URL。
  /// - Returns: 与 Android 通道契约一致的文件事实字典。
  private func copyToTemporaryFile(_ sourceURL: URL) throws -> [String: Any] {
    guard sourceURL.isFileURL else {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_READ_FAILED",
        message: "外部 TXT 文件地址无效"
      )
    }
    /// 文件提供方 URL 可能需要安全作用域访问；返回 false 时仍可能已位于 App Inbox。
    let startedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if startedSecurityScope {
        sourceURL.stopAccessingSecurityScopedResource()
      }
      deleteOwnedInboxCopyIfNeeded(sourceURL)
    }

    /// 协调 iCloud Drive 和第三方文件提供方下载或读取当前文档。
    let coordinator = NSFileCoordinator(filePresenter: nil)
    /// 文件提供方协调失败时返回的系统错误。
    var coordinationError: NSError?
    /// 协调闭包内部产生的受控复制错误。
    var copyError: Error?
    /// 协调读取完成后返回给 Dart 的临时文件事实。
    var payload: [String: Any]?
    coordinator.coordinate(
      readingItemAt: sourceURL,
      options: .withoutChanges,
      error: &coordinationError
    ) { [weak self] coordinatedURL in
      guard let self else {
        copyError = ExternalTxtOpenBridgeError(
          code: "EXTERNAL_TXT_READ_FAILED",
          message: "外部 TXT 文件读取服务已释放，请重新打开文件"
        )
        return
      }
      do {
        payload = try self.copyCoordinatedFile(coordinatedURL)
      } catch {
        copyError = error
      }
    }
    if let copyError {
      throw copyError
    }
    if coordinationError != nil {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_READ_FAILED",
        message: "文件提供方尚未准备好该 TXT，请稍后重新打开"
      )
    }
    guard let payload else {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_READ_FAILED",
        message: "无法读取外部 TXT 文件，请重新打开该文件"
      )
    }
    return payload
  }

  /// 对已经由文件协调器开放的 URL 执行元数据校验和有界流式复制。
  ///
  /// - Parameter sourceURL: `NSFileCoordinator` 提供的当前可读 URL。
  /// - Returns: Dart 导入确认页可以立即使用的临时文件事实。
  private func copyCoordinatedFile(_ sourceURL: URL) throws -> [String: Any] {
    /// 系统文件资源值仅用于提前校验，复制过程仍会独立计数。
    let resourceValues = try sourceURL.resourceValues(
      forKeys: [.nameKey, .fileSizeKey, .isRegularFileKey]
    )
    if resourceValues.isRegularFile == false {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_READ_FAILED",
        message: "当前外部打开入口只能接收普通 TXT 文件"
      )
    }
    /// 优先使用文件提供方声明的安全显示名，缺失时回退 URL 末段。
    let declaredName = resourceValues.name?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    /// 交给导入确认页展示的最终文件名。
    let displayName: String
    if let declaredName, !declaredName.isEmpty {
      displayName = declaredName
    } else {
      displayName = sourceURL.lastPathComponent
    }
    guard !displayName.isEmpty,
          displayName.lowercased().hasSuffix(".txt") else {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_UNSUPPORTED",
        message: "当前外部打开入口只支持 TXT 文件"
      )
    }
    /// 提供方声明的大小只用于提前拒绝，不能替代复制过程中的真实计数。
    let declaredSize = Int64(resourceValues.fileSize ?? -1)
    if declaredSize == 0 {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_EMPTY",
        message: "不能导入空 TXT 文件"
      )
    }
    if declaredSize > Self.maxBookBytes {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_TOO_LARGE",
        message: "单本书不能超过 1 GiB"
      )
    }

    /// 专用临时目录内的随机文件名，同时作为 Dart 释放副本的一次性 token。
    let token = "\(UUID().uuidString.lowercased()).txt"
    /// 复制尚未完成时使用的同目录文件，避免 Dart 读取半本书。
    let importingURL = try cacheDirectory().appendingPathComponent(
      "\(token).importing",
      isDirectory: false
    )
    /// 完整复制后才对 Dart 可见的临时文件。
    let completedURL = try cacheDirectory().appendingPathComponent(
      token,
      isDirectory: false
    )
    do {
      if fileManager.fileExists(atPath: importingURL.path) {
        try fileManager.removeItem(at: importingURL)
      }
      if fileManager.fileExists(atPath: completedURL.path) {
        try fileManager.removeItem(at: completedURL)
      }
      guard fileManager.createFile(atPath: importingURL.path, contents: nil) else {
        throw ExternalTxtOpenBridgeError(
          code: "EXTERNAL_TXT_COPY_FAILED",
          message: "创建外部 TXT 临时副本失败，请确认存储空间充足"
        )
      }
      /// 实际复制字节数，用于识别空文件和提供方谎报大小。
      let copiedBytes = try copyFileContents(
        from: sourceURL,
        to: importingURL
      )
      if copiedBytes == 0 {
        throw ExternalTxtOpenBridgeError(
          code: "EXTERNAL_TXT_EMPTY",
          message: "不能导入空 TXT 文件"
        )
      }
      try fileManager.moveItem(at: importingURL, to: completedURL)
      return [
        "path": completedURL.path,
        "name": displayName,
        "size": copiedBytes,
        "token": token,
      ]
    } catch {
      try? fileManager.removeItem(at: importingURL)
      try? fileManager.removeItem(at: completedURL)
      throw error
    }
  }

  /// 使用固定大小分块把外部文件复制到专用临时文件，并在返回前关闭全部句柄。
  ///
  /// - Parameters:
  ///   - sourceURL: 文件提供方当前可读 URL。
  ///   - destinationURL: 已创建但尚未写入的 `.importing` 文件。
  /// - Returns: 实际写入的总字节数。
  private func copyFileContents(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws -> Int64 {
    /// 当前外部 TXT 的只读文件句柄。
    let input = try FileHandle(forReadingFrom: sourceURL)
    defer {
      try? input.close()
    }
    /// 当前 cache 临时文件的写入句柄。
    let output = try FileHandle(forWritingTo: destinationURL)
    defer {
      try? output.close()
    }
    /// 已流式复制的真实字节数。
    var copiedBytes: Int64 = 0
    while true {
      /// 当前固定大小分块；EOF 时返回 nil 或空数据。
      let data = try input.read(upToCount: Self.copyBufferBytes) ?? Data()
      if data.isEmpty {
        break
      }
      copiedBytes += Int64(data.count)
      if copiedBytes > Self.maxBookBytes {
        throw ExternalTxtOpenBridgeError(
          code: "EXTERNAL_TXT_TOO_LARGE",
          message: "单本书不能超过 1 GiB"
        )
      }
      try output.write(contentsOf: data)
    }
    try output.synchronize()
    return copiedBytes
  }

  /// 返回外部 TXT 专用 cache 目录，并确保目录已经创建。
  ///
  /// - Returns: App 沙盒内不会被数据库持久化的临时目录 URL。
  private func cacheDirectory() throws -> URL {
    guard let cachesURL = fileManager.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first else {
      throw ExternalTxtOpenBridgeError(
        code: "EXTERNAL_TXT_COPY_FAILED",
        message: "无法访问应用临时目录，请稍后重试"
      )
    }
    /// 外部 TXT 临时副本的独立子目录。
    let directoryURL = cachesURL.appendingPathComponent(
      Self.cacheDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    return directoryURL
  }

  /// 删除超过生命周期上限的完整副本和未完成 `.importing` 文件。
  private func deleteStaleFiles() {
    do {
      /// 当前专用 cache 目录下的直接子文件。
      let files = try fileManager.contentsOfDirectory(
        at: cacheDirectory(),
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
      /// 本次清理判断使用的统一当前时间。
      let now = Date()
      for fileURL in files {
        /// 文件最后修改时间缺失时不主动删除，避免误清理未知项。
        let modifiedAt = try? fileURL.resourceValues(
          forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        guard let modifiedAt,
              now.timeIntervalSince(modifiedAt) > Self.staleFileAge else {
          continue
        }
        try? fileManager.removeItem(at: fileURL)
      }
    } catch {
      // cache 目录不可用或枚举失败不影响 App 启动，后续初始化会再次清理。
    }
  }

  /// 删除系统因“不原地打开”投递到本 App `Documents/Inbox` 的一次性副本。
  ///
  /// 文件提供方原 URL、用户 Documents 其他位置及应用私有正式书籍目录都不会被删除。
  ///
  /// - Parameter sourceURL: Scene 本次交付的源文件 URL。
  private func deleteOwnedInboxCopyIfNeeded(_ sourceURL: URL) {
    guard let documentsURL = fileManager.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      return
    }
    /// iOS 文档交互在不支持原地打开时使用的 App 自有 Inbox 目录。
    let inboxURL = documentsURL.appendingPathComponent(
      "Inbox",
      isDirectory: true
    ).standardizedFileURL
    /// 标准化后的源文件父目录，用于拒绝路径前缀碰撞和目录穿越。
    let sourceParentURL = sourceURL.standardizedFileURL.deletingLastPathComponent()
    guard sourceParentURL.path == inboxURL.path else {
      return
    }
    try? fileManager.removeItem(at: sourceURL)
  }

  /// 校验清理 token 只能表示本桥生成的 UUID `.txt` 文件名。
  ///
  /// - Parameter token: Dart 原样返回的一次性标识。
  /// - Returns: 是否可以安全映射到专用 cache 目录的直接子文件。
  private func isSafeToken(_ token: String) -> Bool {
    if token != URL(fileURLWithPath: token).lastPathComponent ||
        !token.lowercased().hasSuffix(".txt") {
      return false
    }
    /// 去掉扩展名后的 UUID 文本。
    let uuidText = String(token.dropLast(4))
    return UUID(uuidString: uuidText) != nil
  }

  /// 通知 Dart 存在可消费的冷启动或热启动请求，不传递文件内容。
  private func notifyRequestAvailable() {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("externalTxtOpenAvailable", arguments: nil)
    }
  }

  /// 把文件队列结果切回主线程完成 Flutter 回调。
  ///
  /// - Parameters:
  ///   - result: Flutter 当前调用的结果回调。
  ///   - value: 返回给 Dart 的可空平台值。
  private static func postResult(
    _ result: @escaping FlutterResult,
    value: Any?
  ) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  /// 把受控平台错误切回主线程交给 Dart 展示。
  ///
  /// - Parameters:
  ///   - result: Flutter 当前调用的结果回调。
  ///   - error: 不包含文件路径或正文的安全错误。
  private static func postError(
    _ result: @escaping FlutterResult,
    error: ExternalTxtOpenBridgeError
  ) {
    DispatchQueue.main.async {
      result(
        FlutterError(
          code: error.code,
          message: error.message,
          details: nil
        )
      )
    }
  }

  /// App 沙盒文件操作入口，集中便于保持所有路径都在专用 cache 下。
  private var fileManager: FileManager {
    FileManager.default
  }
}

/// 表示 iOS 外部 TXT 宿主边界可直接展示的受控错误。
private struct ExternalTxtOpenBridgeError: Error {
  /// 稳定平台错误码，供 Dart 保留问题分类。
  let code: String

  /// 不包含文件路径、文件名和正文的中文提示。
  let message: String
}
