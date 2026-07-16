import 'android_log_writer.dart';
import 'app_logger.dart';

/// 将非敏感日志输出到 Flutter 调试控制台的 M1 默认实现。
///
/// Release 模式不会输出，后续如接入持久化或远程上报，只需替换组合根注册的实现。
final class ConsoleAppLogger implements AppLogger {
  /// 创建无状态控制台日志器。
  const ConsoleAppLogger();

  /// 控制台实现同样通过原生通道写入真实 Android Logcat Tag。
  static const AndroidLogWriter _androidLogWriter = AndroidLogWriter();

  /// 输出开发阶段诊断信息。
  @override
  void debug({required String message, String tag = appLogTag}) {
    _write(level: AppLogLevel.debug, message: message, tag: tag);
  }

  /// 输出正常的重要状态变化。
  @override
  void info({required String message, String tag = appLogTag}) {
    _write(level: AppLogLevel.info, message: message, tag: tag);
  }

  /// 输出可恢复异常及其错误摘要。
  @override
  void warning({
    required String message,
    String tag = appLogTag,
    Object? error,
  }) {
    _write(level: AppLogLevel.warning, message: message, tag: tag, error: error);
  }

  /// 输出操作失败信息、原始错误及堆栈。
  @override
  void error({
    required String message,
    String tag = appLogTag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      level: AppLogLevel.error,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 输出关键流程无法继续的严重错误及其堆栈摘要。
  @override
  void fatal({
    required String message,
    String tag = appLogTag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      level: AppLogLevel.fatal,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 统一格式化控制台输出，避免不同调用点自行拼接日志格式。
  void _write({
    required AppLogLevel level,
    required String message,
    required String tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    /// 带扫码稳定标识的日志自动进入二维码书源专用 Logcat Tag。
    final String resolvedTag = resolveAppLogTag(
      message: message,
      requestedTag: tag,
    );
    _androidLogWriter.write(level: level, tag: resolvedTag, message: message);
    if (error case final Object resolvedError) {
      /// 原始错误文本可能包含 Cookie、用户输入或绝对路径，因此只输出类型。
      final String errorType = resolvedError.runtimeType.toString();
      _androidLogWriter.write(
        level: level,
        tag: resolvedTag,
        message: 'errorType=$errorType',
      );
    }
    if (stackTrace != null) {
      // 堆栈常包含本机绝对路径；M1 控制台实现只标记其存在，不直接输出内容。
      _androidLogWriter.write(
        level: level,
        tag: resolvedTag,
        message: 'stackTrace=omitted',
      );
    }
  }
}
