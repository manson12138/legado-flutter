import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// 将非敏感日志输出到 Flutter 调试控制台的 M1 默认实现。
///
/// Release 模式不会输出，后续如接入持久化或远程上报，只需替换组合根注册的实现。
final class ConsoleAppLogger implements AppLogger {
  /// 创建无状态控制台日志器。
  const ConsoleAppLogger();

  /// 输出开发阶段诊断信息。
  @override
  void debug({required String message}) {
    _write(level: AppLogLevel.debug, message: message);
  }

  /// 输出正常的重要状态变化。
  @override
  void info({required String message}) {
    _write(level: AppLogLevel.info, message: message);
  }

  /// 输出可恢复异常及其错误摘要。
  @override
  void warning({required String message, Object? error}) {
    _write(level: AppLogLevel.warning, message: message, error: error);
  }

  /// 输出操作失败信息、原始错误及堆栈。
  @override
  void error({
    required String message,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      level: AppLogLevel.error,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 统一格式化控制台输出，避免不同调用点自行拼接日志格式。
  void _write({
    required AppLogLevel level,
    required String message,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!kDebugMode) {
      return;
    }

    /// 当前日志级别的稳定文本名称。
    final String levelName = level.name.toUpperCase();
    debugPrint('[LEGADO_FLUTTER][$levelName] $message');
    if (error case final Object resolvedError) {
      /// 原始错误文本可能包含 Cookie、用户输入或绝对路径，因此只输出类型。
      final String errorType = resolvedError.runtimeType.toString();
      debugPrint('[LEGADO_FLUTTER][$levelName] errorType=$errorType');
    }
    if (stackTrace != null) {
      // 堆栈常包含本机绝对路径；M1 控制台实现只标记其存在，不直接输出内容。
      debugPrint('[LEGADO_FLUTTER][$levelName] stackTrace=omitted');
    }
  }
}
