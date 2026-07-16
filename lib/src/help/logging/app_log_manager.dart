/// 描述日志管理页面可以展示和操作的单个沙盒日志文件。
final class AppLogFile {
  /// 创建只读日志文件信息。
  const AppLogFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  /// 日志文件在应用私有沙盒内的绝对路径，只交给日志管理实现使用。
  final String path;

  /// 由日期和当日序号组成的安全文件名。
  final String name;

  /// 当前日志文件的字节数。
  final int sizeBytes;

  /// 文件最后修改时间。
  final DateTime modifiedAt;
}

/// 定义设置页管理沙盒日志所需的统一能力。
abstract interface class AppLogManager {
  /// 按最新修改时间优先读取全部日志文件信息。
  Future<List<AppLogFile>> listLogFiles();

  /// 读取指定日志文件的完整 UTF-8 文本，供应用内查看。
  Future<String> readLogFile(AppLogFile file);

  /// 删除指定日志文件。
  Future<void> deleteLogFile(AppLogFile file);

  /// 删除当前沙盒日志目录内的全部日志文件。
  Future<void> deleteAllLogFiles();

  /// 把指定日志文件完整分段输出到 ADB logcat。
  Future<void> echoLogFileToAdb(AppLogFile file);
}
