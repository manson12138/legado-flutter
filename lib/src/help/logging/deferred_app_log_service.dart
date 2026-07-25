import 'app_log_manager.dart';
import 'app_logger.dart';
import 'console_app_logger.dart';
import 'file_app_logger.dart';

/// 首帧前使用控制台、文件能力就绪后原子切换到文件日志的延后日志服务。
final class DeferredAppLogService implements AppLogger, AppLogManager {
  /// 创建以控制台日志为降级实现的延后日志服务。
  DeferredAppLogService() : _logger = const ConsoleAppLogger();

  /// 当前实际写入实现；切换后既有持有本对象的业务无需重建。
  AppLogger _logger;

  /// 已就绪的文件日志管理能力；空表示目录仍在后台创建。
  FileAppLogger? _fileLogger;

  /// 将后续日志与设置页管理操作切换到已完成初始化的文件实现。
  void activate(FileAppLogger logger) {
    _fileLogger = logger;
    _logger = logger;
  }

  @override
  void debug({required String message, String tag = appLogTag}) =>
      _logger.debug(message: message, tag: tag);

  @override
  void info({required String message, String tag = appLogTag}) =>
      _logger.info(message: message, tag: tag);

  @override
  void warning({required String message, String tag = appLogTag, Object? error}) =>
      _logger.warning(message: message, tag: tag, error: error);

  @override
  void error({required String message, String tag = appLogTag, Object? error, StackTrace? stackTrace}) =>
      _logger.error(message: message, tag: tag, error: error, stackTrace: stackTrace);

  @override
  void fatal({required String message, String tag = appLogTag, Object? error, StackTrace? stackTrace}) =>
      _logger.fatal(message: message, tag: tag, error: error, stackTrace: stackTrace);

  /// 日志目录尚未就绪时返回空列表；页面稍后刷新即可读取文件日志。
  @override
  Future<List<AppLogFile>> listLogFiles() async =>
      _fileLogger?.listLogFiles() ?? const <AppLogFile>[];

  /// 防止初始化中的日志管理页读取不存在的文件。
  @override
  Future<String> readLogFile(AppLogFile file) => _requireFileLogger().readLogFile(file);

  /// 防止初始化中的日志管理页修改不存在的文件。
  @override
  Future<void> deleteLogFile(AppLogFile file) => _requireFileLogger().deleteLogFile(file);

  /// 文件目录未就绪时没有可删除的日志，直接安全返回。
  @override
  Future<void> deleteAllLogFiles() => _fileLogger?.deleteAllLogFiles() ?? Future<void>.value();

  /// 防止初始化中的日志管理页向 ADB 输出不存在的文件。
  @override
  Future<void> echoLogFileToAdb(AppLogFile file) => _requireFileLogger().echoLogFileToAdb(file);

  /// 取得已激活文件实现；只会在用户已进入日志管理页时调用。
  FileAppLogger _requireFileLogger() =>
      _fileLogger ?? (throw StateError('日志文件仍在初始化'));
}
