import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import 'app_log_manager.dart';
import 'app_logger.dart';
import 'android_log_writer.dart';

/// 同时提供优先级、格式化、沙盒轮转和 ADB 回显能力的应用日志实现。
final class FileAppLogger implements AppLogger, AppLogManager {
  /// 每个日志文件允许占用的最大字节数，固定为 5 MiB。
  static const int _maximumFileBytes = 5 * 1024 * 1024;

  /// 单条超长日志拆分后的最大字节数，确保文件轮转前保留完整 UTF-8 字符。
  static const int _maximumRecordBodyBytes = 512 * 1024;

  /// 无换行长文本自动补换行时使用的字符数，避免查看器和控制台吞掉尾部内容。
  static const int _longLineCharacters = 4000;

  /// ADB 单次输出的最大字符数，低于 Android logcat 单条消息限制。
  static const int _adbChunkCharacters = 3000;

  /// 日志文件名必须满足的日期与序号格式。
  static final RegExp _logFileNamePattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}_\d{3,}\.log$',
  );

  /// 创建已经绑定日志目录的实现；调用方应通过 [create] 完成目录初始化。
  FileAppLogger._({required Directory logDirectory})
      : _logDirectory = logDirectory;

  /// 创建沙盒日志器，并确保应用支持目录下的 logs 子目录已经存在。
  static Future<FileAppLogger> create() async {
    /// 应用支持目录位于 Android/iOS 私有沙盒，不需要存储权限。
    final Directory supportDirectory = await getApplicationSupportDirectory();
    /// 日志使用独立子目录，避免删除日志时影响数据库或其他应用文件。
    final Directory logDirectory = Directory(
      path_util.join(supportDirectory.path, 'logs'),
    );
    if (!await logDirectory.exists()) {
      await logDirectory.create(recursive: true);
    }
    return FileAppLogger._(logDirectory: logDirectory);
  }

  /// 应用私有日志目录。
  final Directory _logDirectory;

  /// 把所有实时日志写入 Android 原生 Logcat Tag 的平台适配器。
  final AndroidLogWriter _androidLogWriter = const AndroidLogWriter();

  /// 串行化所有文件写入，避免多个异步调用同时选中同一轮转文件。
  Future<void> _pendingWrite = Future<void>.value();

  /// 当前正在追加的日志文件；被删除或跨日期后会重新选择。
  File? _currentFile;

  /// 当前文件对应的本地日期文本。
  String? _currentDate;

  /// 记录开发阶段诊断日志。
  @override
  void debug({required String message, String tag = appLogTag}) {
    _enqueue(
      level: AppLogLevel.debug,
      message: message,
      tag: tag,
    );
  }

  /// 记录正常状态变化日志。
  @override
  void info({required String message, String tag = appLogTag}) {
    _enqueue(
      level: AppLogLevel.info,
      message: message,
      tag: tag,
    );
  }

  /// 记录可恢复异常日志。
  @override
  void warning({
    required String message,
    String tag = appLogTag,
    Object? error,
  }) {
    _enqueue(
      level: AppLogLevel.warning,
      message: message,
      tag: tag,
      error: error,
    );
  }

  /// 记录当前操作失败日志。
  @override
  void error({
    required String message,
    String tag = appLogTag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _enqueue(
      level: AppLogLevel.error,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 记录关键流程无法继续的最高优先级日志。
  @override
  void fatal({
    required String message,
    String tag = appLogTag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _enqueue(
      level: AppLogLevel.fatal,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 格式化日志并加入顺序写入队列，调用业务代码不需要等待磁盘 I/O。
  void _enqueue({
    required AppLogLevel level,
    required String message,
    required String tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    /// 在调用发生时固定时间，避免队列繁忙时日志时间变成实际落盘时间。
    final DateTime occurredAt = DateTime.now();
    /// 带扫码稳定标识的日志自动进入二维码书源专用 Logcat Tag。
    final String resolvedTag = resolveAppLogTag(
      message: message,
      requestedTag: tag,
    );
    _pendingWrite = _pendingWrite
        .then((_) async {
          await _write(
            occurredAt: occurredAt,
            level: level,
            message: message,
            tag: resolvedTag,
            error: error,
            stackTrace: stackTrace,
          );
        })
        .catchError((Object writeError, StackTrace writeStackTrace) {
          /// 文件系统异常不能再次写入自身，否则会形成无限递归。
          _androidLogWriter.write(
            level: AppLogLevel.error,
            tag: appLogTag,
            message: 'LOGGER_ERROR ${writeError.runtimeType}: $writeError\n'
                '$writeStackTrace',
          );
        });
  }

  /// 把一条逻辑日志整理为一个或多个完整记录并依次写入。
  Future<void> _write({
    required DateTime occurredAt,
    required AppLogLevel level,
    required String message,
    required String tag,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    /// JSON 内容会缩进，普通超长单行内容会主动补换行。
    final String formattedMessage = _formatMessage(message);
    /// 错误对象和堆栈作为正文的一部分保留，便于日志文件完整排查。
    final StringBuffer body = StringBuffer(formattedMessage);
    if (error case final Object resolvedError) {
      body
        ..writeln()
        ..write('error=${resolvedError.runtimeType}: $resolvedError');
    }
    if (stackTrace case final StackTrace resolvedStackTrace) {
      body
        ..writeln()
        ..writeln('stackTrace:')
        ..write(resolvedStackTrace);
    }

    /// 极端大正文按 UTF-8 字节安全拆分，每一段都有独立时间和优先级头部。
    final List<String> bodyParts = _splitByUtf8Bytes(
      body.toString(),
      _maximumRecordBodyBytes,
    );
    for (int index = 0; index < bodyParts.length; index += 1) {
      /// 只有超长记录才增加分段标识，普通日志保持紧凑。
      final String partLabel = bodyParts.length > 1
          ? '[PART ${index + 1}/${bodyParts.length}] '
          : '';
      /// 单条落盘文本始终以换行结尾，防止下一条日志粘连。
      final String record = '${_formatTimestamp(occurredAt)} '
          '[${level.name.toUpperCase()}] '
          '[$tag] '
          '$partLabel${bodyParts[index]}\n';
      await _appendRecord(record, occurredAt);
      _printToAdb(record, level: level, tag: tag);
    }
  }

  /// 尝试格式化 JSON，并为没有换行的超长普通文本按固定宽度补换行。
  String _formatMessage(String message) {
    final String trimmedMessage = message.trim();
    if (trimmedMessage.isEmpty) {
      return '<empty>';
    }
    if ((trimmedMessage.startsWith('{') && trimmedMessage.endsWith('}')) ||
        (trimmedMessage.startsWith('[') && trimmedMessage.endsWith(']'))) {
      try {
        /// 仅对象和数组进行 JSON 美化，字符串或数字仍按普通文本输出。
        final Object? decodedValue = jsonDecode(trimmedMessage);
        if (decodedValue is Map || decodedValue is List) {
          return const JsonEncoder.withIndent('  ').convert(decodedValue);
        }
      } on FormatException {
        /// 类似 JSON 但格式不合法时保留原文，不能因为格式化失败丢失日志。
      }
    }
    if (!message.contains('\n') && message.length > _longLineCharacters) {
      return _splitByCharacterCount(message, _longLineCharacters).join('\n');
    }
    return message;
  }

  /// 在不丢字符的前提下按字符数量拆分文本。
  List<String> _splitByCharacterCount(String value, int maximumCharacters) {
    final List<String> parts = <String>[];
    final StringBuffer part = StringBuffer();
    int characterCount = 0;
    for (final int rune in value.runes) {
      part.writeCharCode(rune);
      characterCount += 1;
      if (characterCount >= maximumCharacters) {
        parts.add(part.toString());
        part.clear();
        characterCount = 0;
      }
    }
    if (part.isNotEmpty || parts.isEmpty) {
      parts.add(part.toString());
    }
    return parts;
  }

  /// 按 UTF-8 实际字节数拆分文本，确保跨文件轮转时不会截断多字节字符。
  List<String> _splitByUtf8Bytes(String value, int maximumBytes) {
    final List<String> parts = <String>[];
    final StringBuffer part = StringBuffer();
    int partBytes = 0;
    for (final int rune in value.runes) {
      final String character = String.fromCharCode(rune);
      final int characterBytes = utf8.encode(character).length;
      if (partBytes > 0 && partBytes + characterBytes > maximumBytes) {
        parts.add(part.toString());
        part.clear();
        partBytes = 0;
      }
      part.write(character);
      partBytes += characterBytes;
    }
    if (part.isNotEmpty || parts.isEmpty) {
      parts.add(part.toString());
    }
    return parts;
  }

  /// 在写入前检查 5 MiB 上限，必要时切换到同日期的下一个序号文件。
  Future<void> _appendRecord(String record, DateTime occurredAt) async {
    final List<int> encodedRecord = utf8.encode(record);
    File targetFile = await _resolveWritableFile(occurredAt);
    int targetLength = await targetFile.length();
    if (targetLength > 0 &&
        targetLength + encodedRecord.length > _maximumFileBytes) {
      targetFile = await _createNextFile(_formatDate(occurredAt));
      targetLength = 0;
    }
    if (targetLength + encodedRecord.length <= _maximumFileBytes) {
      await targetFile.writeAsBytes(encodedRecord, mode: FileMode.append, flush: true);
    }
  }

  /// 复用当前未满文件；日期变化、文件消失或文件已满时重新选择。
  Future<File> _resolveWritableFile(DateTime occurredAt) async {
    final String date = _formatDate(occurredAt);
    final File? currentFile = _currentFile;
    if (_currentDate == date &&
        currentFile != null &&
        await currentFile.exists() &&
        await currentFile.length() < _maximumFileBytes) {
      return currentFile;
    }

    final List<File> sameDateFiles = await _filesForDate(date);
    if (sameDateFiles.isNotEmpty) {
      final File latestFile = sameDateFiles.last;
      if (await latestFile.length() < _maximumFileBytes) {
        _currentDate = date;
        _currentFile = latestFile;
        return latestFile;
      }
    }
    return _createNextFile(date);
  }

  /// 创建指定日期的下一个三位序号日志文件。
  Future<File> _createNextFile(String date) async {
    final List<File> sameDateFiles = await _filesForDate(date);
    int nextSequence = 1;
    if (sameDateFiles.isNotEmpty) {
      final String latestName = path_util.basename(sameDateFiles.last.path);
      final String sequenceText = latestName.substring(11, latestName.length - 4);
      nextSequence = (int.tryParse(sequenceText) ?? 0) + 1;
    }
    final String fileName = '${date}_${nextSequence.toString().padLeft(3, '0')}.log';
    final File nextFile = File(path_util.join(_logDirectory.path, fileName));
    await nextFile.create(recursive: true);
    _currentDate = date;
    _currentFile = nextFile;
    return nextFile;
  }

  /// 读取指定日期日志并按文件名序号升序排列。
  Future<List<File>> _filesForDate(String date) async {
    final List<File> files = await _listValidFiles();
    files.removeWhere((File file) {
      return !path_util.basename(file.path).startsWith('${date}_');
    });
    files.sort((File first, File second) => first.path.compareTo(second.path));
    return files;
  }

  /// 仅返回本日志器命名规则创建的普通文件，忽略目录内其他内容。
  Future<List<File>> _listValidFiles() async {
    if (!await _logDirectory.exists()) {
      await _logDirectory.create(recursive: true);
    }
    final List<File> files = <File>[];
    await for (final FileSystemEntity entity in _logDirectory.list()) {
      if (entity is File &&
          _logFileNamePattern.hasMatch(path_util.basename(entity.path))) {
        files.add(entity);
      }
    }
    return files;
  }

  /// 等待已排队日志完成后，读取最新优先的日志文件元数据。
  @override
  Future<List<AppLogFile>> listLogFiles() async {
    await _pendingWrite;
    final List<File> files = await _listValidFiles();
    final List<AppLogFile> result = <AppLogFile>[];
    for (final File file in files) {
      final FileStat stat = await file.stat();
      result.add(
        AppLogFile(
          path: file.path,
          name: path_util.basename(file.path),
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    result.sort(
      (AppLogFile first, AppLogFile second) =>
          second.modifiedAt.compareTo(first.modifiedAt),
    );
    return result;
  }

  /// 完整读取经过目录边界验证的 UTF-8 日志文件。
  @override
  Future<String> readLogFile(AppLogFile file) async {
    await _pendingWrite;
    final File safeFile = _resolveManagedFile(file);
    return safeFile.readAsString();
  }

  /// 删除经过目录边界验证的单个日志文件，并清理当前文件缓存。
  @override
  Future<void> deleteLogFile(AppLogFile file) async {
    await _pendingWrite;
    final File safeFile = _resolveManagedFile(file);
    if (await safeFile.exists()) {
      await safeFile.delete();
    }
    if (_currentFile?.path == safeFile.path) {
      _currentFile = null;
      _currentDate = null;
    }
  }

  /// 删除全部合法日志文件，不触碰日志目录内的其他未知文件。
  @override
  Future<void> deleteAllLogFiles() async {
    await _pendingWrite;
    final List<File> files = await _listValidFiles();
    for (final File file in files) {
      await file.delete();
    }
    _currentFile = null;
    _currentDate = null;
  }

  /// 完整读取指定文件并以稳定标签、固定长度分段回显到 ADB。
  @override
  Future<void> echoLogFileToAdb(AppLogFile file) async {
    final String content = await readLogFile(file);
    _printToAdb(
      content,
      level: AppLogLevel.info,
      tag: appLogTag,
      prefix: '[LOG_ECHO][${file.name}] ',
    );
  }

  /// 校验文件名和父目录，阻止页面参数越过日志沙盒边界。
  File _resolveManagedFile(AppLogFile file) {
    final String fileName = path_util.basename(file.path);
    final String parentPath = path_util.normalize(path_util.dirname(file.path));
    final String logDirectoryPath = path_util.normalize(_logDirectory.path);
    if (!_logFileNamePattern.hasMatch(fileName) ||
        parentPath != logDirectoryPath) {
      throw ArgumentError.value(file.path, 'file', '不是受管理的日志文件');
    }
    return File(path_util.join(_logDirectory.path, fileName));
  }

  /// 以低于 logcat 限制的长度逐段输出，确保超长且无换行文本不会被截断。
  void _printToAdb(
    String value, {
    required AppLogLevel level,
    required String tag,
    String prefix = '',
  }) {
    final List<String> lines = value.split('\n');
    for (final String line in lines) {
      final List<String> chunks = _splitByCharacterCount(
        line,
        _adbChunkCharacters,
      );
      for (final String chunk in chunks) {
        /// 每个分段独立交给原生 Logcat；空行也保留，从而维持原日志格式。
        _androidLogWriter.write(
          level: level,
          tag: tag,
          message: '$prefix$chunk',
        );
      }
    }
  }

  /// 把时间格式化为带本地时区偏移的固定宽度日志时间戳。
  String _formatTimestamp(DateTime value) {
    final Duration offset = value.timeZoneOffset;
    final String sign = offset.isNegative ? '-' : '+';
    final Duration absoluteOffset = offset.abs();
    final String offsetHours = absoluteOffset.inHours.toString().padLeft(2, '0');
    final String offsetMinutes = (absoluteOffset.inMinutes % 60)
        .toString()
        .padLeft(2, '0');
    return '${_formatDate(value)}T'
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}.'
        '${value.millisecond.toString().padLeft(3, '0')}'
        '$sign$offsetHours:$offsetMinutes';
  }

  /// 把本地日期格式化为日志文件名和时间戳共用的 yyyy-MM-dd 文本。
  String _formatDate(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }
}
