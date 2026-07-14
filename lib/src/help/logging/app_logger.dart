/// 【扫码诊断日志】扫一扫添加书源全链路统一日志标识。
const String bookSourceQrScanLogTag = '[BOOK_SOURCE_QR_SCAN]';

/// 应用日志严重级别，用于让输出实现选择合适的展示或持久化策略。
enum AppLogLevel {
  /// 开发阶段诊断信息，不能包含账号、Cookie、Token 或正文隐私数据。
  debug,

  /// 正常生命周期或重要状态变化信息。
  info,

  /// 可恢复但需要关注的异常状态。
  warning,

  /// 导致当前操作失败或越过全局边界的错误。
  error,
}

/// 定义应用统一日志能力，业务层不直接依赖控制台或第三方日志库。
abstract interface class AppLogger {
  /// 记录开发阶段诊断信息。
  void debug({required String message});

  /// 记录正常的重要状态变化。
  void info({required String message});

  /// 记录可恢复异常，并可附带原始错误对象。
  void warning({required String message, Object? error});

  /// 记录导致操作失败的错误及可选堆栈。
  void error({
    required String message,
    Object? error,
    StackTrace? stackTrace,
  });
}
