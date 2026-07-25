import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

/// 崩溃报告统一标识；本功能的诊断输出如有需要必须使用此标识。
const String crashReportingLogTag = 'LEGADO_CRASH_REPORT';

/// 崩溃报告的上传状态，状态随单个报告原子写回其自身文件。
enum CrashReportUploadState { pending, uploading, uploaded, failed }

/// 供页面展示和操作的一份独立崩溃报告摘要。
final class CrashReportFile {
  /// 创建只包含脱敏元数据的崩溃报告文件摘要。
  const CrashReportFile({required this.path, required this.reportId, required this.occurredAt, required this.source, required this.exceptionType, required this.sizeBytes, required this.uploadState, this.receiptId});

  /// 应用私有目录中的绝对路径，仅交由报告管理器和系统分享使用。
  final String path;
  /// 服务端幂等使用的随机报告标识。
  final String reportId;
  /// 报告发生时间。
  final DateTime occurredAt;
  /// 捕获异常的受控来源。
  final String source;
  /// 脱敏后的异常类型。
  final String exceptionType;
  /// 当前文件大小。
  final int sizeBytes;
  /// 本地保存的上传状态。
  final CrashReportUploadState uploadState;
  /// 服务端接受后返回的可选回执。
  final String? receiptId;
}

/// 崩溃上传成功后由网络边界返回的受控结果。
final class CrashReportUploadReceipt {
  /// 创建服务端已接收或已去重的回执。
  const CrashReportUploadReceipt({required this.receiptId, required this.retentionDays});

  /// 服务端回执标识。
  final String receiptId;
  /// 服务端原始报告保留天数。
  final int retentionDays;
}

/// 应用私有崩溃报告的落盘、脱敏、列表、上传状态和保留上限管理器。
final class CrashReportManager {
  /// 单份报告最大 UTF-8 字节数，保持低于后端 64 KiB 限制。
  static const int _maximumReportBytes = 60 * 1024;
  /// 报告数量上限，防止长期离线占用应用存储。
  static const int _maximumReportCount = 30;
  /// 崩溃目录总量上限。
  static const int _maximumDirectoryBytes = 2 * 1024 * 1024;

  /// 创建并初始化应用支持目录中的独立崩溃报告目录。
  static Future<CrashReportManager> create({required int productId, required String versionName, required int versionCode, required String channel}) async {
    final CrashReportManager manager = CrashReportManager.deferred(productId: productId, versionName: versionName, versionCode: versionCode, channel: channel);
    await manager.initialize();
    return manager;
  }

  /// 创建可在首帧前使用的崩溃管理器；目录在 [initialize] 中异步准备。
  CrashReportManager.deferred({required int productId, required String versionName, required int versionCode, required String channel})
      : _productId = productId,
        _versionName = versionName,
        _versionCode = versionCode,
        _channel = channel;

  /// 崩溃报告目录。
  Directory? _directory;
  /// 后端产品标识。
  final int _productId;
  /// 当前语义版本名。
  final String _versionName;
  /// 当前构建号。
  final int _versionCode;
  /// 当前发布渠道。
  final String _channel;
  /// 串行化文件读写，避免并发改写同一上传状态。
  Future<void> _pendingOperation = Future<void>.value();
  /// App 组合根在网络和认证依赖就绪后注入的上传实现。
  Future<CrashReportUploadReceipt> Function(Map<String, Object?> payload)? _uploader;
  /// 最近一次相同异常的内存去重键。
  String? _lastFingerprint;
  /// 最近一次相同异常的记录时间。
  DateTime? _lastOccurredAt;

  /// 后台创建报告目录；目录失败时全局错误处理继续保持日志降级而不阻塞页面。
  Future<void> initialize() async {
    if (_directory != null) {
      return;
    }
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final Directory directory = Directory(path_util.join(supportDirectory.path, 'crash-reports'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _directory = directory;
  }

  /// 注入专用网络上传能力；不保存 Token，Token 由调用方在每次上传时即时提供。
  void configureUploader(Future<CrashReportUploadReceipt> Function(Map<String, Object?> payload) uploader) {
    _uploader = uploader;
  }

  /// 尽力记录一次未捕获异常；写盘失败不再抛出，避免错误处理递归。
  void record({required String source, required Object error, required StackTrace stackTrace}) {
    if (_directory == null) {
      return;
    }
    final DateTime occurredAt = DateTime.now().toUtc();
    final String exceptionType = error.runtimeType.toString();
    final String fingerprint = '$source|$exceptionType|${_sanitize(stackTrace.toString(), maximumLength: 800)}';
    final DateTime? previousAt = _lastOccurredAt;
    if (_lastFingerprint == fingerprint && previousAt != null && occurredAt.difference(previousAt).inSeconds < 2) {
      return;
    }
    _lastFingerprint = fingerprint;
    _lastOccurredAt = occurredAt;
    _enqueue(() async {
      try {
        final Map<String, Object?> payload = _newPayload(source: source, error: error, stackTrace: stackTrace, occurredAt: occurredAt);
        await _writePayload(payload);
        await _enforceRetention();
      } on Object {
        // 崩溃采集失败必须静默降级，不能再次触发全局错误入口。
      }
    });
  }

  /// 按发生时间倒序读取全部可解析报告；损坏文件不会阻断其他报告展示。
  Future<List<CrashReportFile>> listReports() async {
    final Directory? directory = _directory;
    if (directory == null) {
      return const <CrashReportFile>[];
    }
    final List<CrashReportFile> reports = <CrashReportFile>[];
    await for (final FileSystemEntity entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final Map<String, Object?> payload = await _readPayload(entity);
        reports.add(_toFile(entity, payload));
      } on Object {
        // 单个损坏报告不可影响管理页其余报告。
      }
    }
    reports.sort((CrashReportFile left, CrashReportFile right) => right.occurredAt.compareTo(left.occurredAt));
    return reports;
  }

  /// 读取一份报告的格式化 JSON，页面只会看到已脱敏的文件内容。
  Future<String> readReport(CrashReportFile report) async => const JsonEncoder.withIndent('  ').convert(await _readPayload(File(report.path)));

  /// 上传一份未上传或失败的报告；成功后原子写回上传状态。
  Future<void> upload(CrashReportFile report) async {
    final Future<CrashReportUploadReceipt> Function(Map<String, Object?> payload)? uploader = _uploader;
    if (uploader == null) {
      throw StateError('崩溃上传服务尚未初始化');
    }
    await _enqueue(() async {
      final File file = File(report.path);
      final Map<String, Object?> payload = await _readPayload(file);
      final Map<String, Object?> upload = _map(payload['upload']);
      upload['state'] = CrashReportUploadState.uploading.name;
      upload['attemptCount'] = _int(upload['attemptCount']) + 1;
      payload['upload'] = upload;
      await _writePayload(payload, file: file);
      try {
        final Map<String, Object?> outgoing = Map<String, Object?>.from(payload)..['upload'] = <String, Object?>{'attemptCount': upload['attemptCount']};
        final CrashReportUploadReceipt receipt = await uploader(outgoing);
        upload['state'] = CrashReportUploadState.uploaded.name;
        upload['uploadedAt'] = DateTime.now().toUtc().toIso8601String();
        upload['receiptId'] = receipt.receiptId;
        upload.remove('lastFailureCode');
      } on Object {
        upload['state'] = CrashReportUploadState.failed.name;
        upload['lastFailureCode'] = 'UPLOAD_FAILED';
        rethrow;
      } finally {
        payload['upload'] = upload;
        await _writePayload(payload, file: file);
      }
    });
  }

  /// 删除一份报告；调用方必须在 UI 层完成用户确认。
  Future<void> deleteReport(CrashReportFile report) async {
    await _enqueue(() async {
      final File file = File(report.path);
      if (await file.exists()) {
        await file.delete();
      }
    });
  }

  /// 删除目录内所有报告；调用方必须在 UI 层完成用户确认。
  Future<void> deleteAllReports() async {
    final Directory? directory = _directory;
    if (directory == null) {
      return;
    }
    await _enqueue(() async {
      await for (final FileSystemEntity entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.json')) {
          await entity.delete();
        }
      }
    });
  }

  /// 构造仅包含协议白名单字段的本地报告。
  Map<String, Object?> _newPayload({required String source, required Object error, required StackTrace stackTrace, required DateTime occurredAt}) {
    final String reportId = _randomUuid();
    final String summary = _sanitize(error.toString(), maximumLength: 500);
    final String stack = _sanitize(stackTrace.toString(), maximumLength: 48 * 1024);
    return <String, Object?>{
      'schemaVersion': 1,
      'productId': _productId,
      'reportId': reportId,
      'occurredAt': occurredAt.toIso8601String(),
      'source': source,
      'exceptionType': _sanitize(error.runtimeType.toString(), maximumLength: 120),
      'exceptionSummary': summary,
      'stackTrace': stack,
      'app': <String, Object?>{'versionName': _versionName, 'versionCode': _versionCode, 'buildChannel': _channel},
      'runtime': <String, Object?>{'platform': Platform.operatingSystem, 'osVersion': _sanitize(Platform.operatingSystemVersion, maximumLength: 120), 'dartVersion': _sanitize(Platform.version, maximumLength: 120)},
      'upload': <String, Object?>{'state': CrashReportUploadState.pending.name, 'attemptCount': 0, 'uploadedAt': null, 'receiptId': null},
      'truncated': summary.length >= 500 || stack.length >= 48 * 1024,
    };
  }

  /// 原子替换报告文件，进程中断时不会留下半份 JSON。
  Future<void> _writePayload(Map<String, Object?> payload, {File? file}) async {
    String encoded = jsonEncode(payload);
    if (utf8.encode(encoded).length > _maximumReportBytes) {
      payload['stackTrace'] = _sanitize('${payload['stackTrace'] ?? ''}', maximumLength: 24 * 1024);
      payload['truncated'] = true;
      encoded = jsonEncode(payload);
    }
    final String fileName = file == null ? 'crash-${payload['occurredAt']}-${payload['reportId']}.json'.replaceAll(':', '-') : path_util.basename(file.path);
    final Directory? directory = _directory;
    if (directory == null) {
      return;
    }
    final File target = file ?? File(path_util.join(directory.path, fileName));
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(encoded, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await temporary.rename(target.path);
  }

  /// 按优先淘汰最早已上传报告的规则控制目录大小。
  Future<void> _enforceRetention() async {
    final List<CrashReportFile> reports = await listReports();
    int totalBytes = reports.fold<int>(0, (int total, CrashReportFile item) => total + item.sizeBytes);
    final List<CrashReportFile> candidates = List<CrashReportFile>.of(reports)..sort((CrashReportFile left, CrashReportFile right) {
      final int stateOrder = (left.uploadState == CrashReportUploadState.uploaded ? 0 : 1).compareTo(right.uploadState == CrashReportUploadState.uploaded ? 0 : 1);
      return stateOrder != 0 ? stateOrder : left.occurredAt.compareTo(right.occurredAt);
    });
    while (candidates.isNotEmpty && (candidates.length > _maximumReportCount || totalBytes > _maximumDirectoryBytes)) {
      final CrashReportFile discarded = candidates.removeAt(0);
      await File(discarded.path).delete();
      totalBytes -= discarded.sizeBytes;
    }
  }

  /// 读取并验证 JSON 根节点。
  Future<Map<String, Object?>> _readPayload(File file) async {
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('崩溃报告格式无效');
    }
    return decoded.map<String, Object?>((Object? key, Object? value) => key is String ? MapEntry<String, Object?>(key, value) : throw const FormatException('崩溃报告字段无效'));
  }

  /// 将受控 JSON 转换为页面摘要。
  CrashReportFile _toFile(File file, Map<String, Object?> payload) {
    final Map<String, Object?> upload = _map(payload['upload']);
    CrashReportUploadState state = CrashReportUploadState.pending;
    for (final CrashReportUploadState candidate in CrashReportUploadState.values) {
      if (candidate.name == upload['state']) {
        state = candidate;
        break;
      }
    }
    return CrashReportFile(path: file.path, reportId: '${payload['reportId'] ?? ''}', occurredAt: DateTime.tryParse('${payload['occurredAt'] ?? ''}')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0), source: '${payload['source'] ?? 'unknown'}', exceptionType: '${payload['exceptionType'] ?? 'Unknown'}', sizeBytes: file.lengthSync(), uploadState: state, receiptId: upload['receiptId'] is String ? upload['receiptId'] as String : null);
  }

  /// 对异常文本做凭据、URL 查询、路径和长度脱敏。
  String _sanitize(String value, {required int maximumLength}) {
    String sanitized = value.replaceAllMapped(RegExp(r'(authorization|cookie|token|password|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+', caseSensitive: false), (Match match) => '${match.group(1)}=[REDACTED]');
    sanitized = sanitized.replaceAllMapped(RegExp(r'https?://[^\s?]+\?[^\s]+'), (Match match) => '${match.group(0)?.split('?').first}?[QUERY_REDACTED]');
    sanitized = sanitized.replaceAll(RegExp(r'([A-Za-z]:\\|/)(?:[^\s/\\]+[\\/])+'), '[PATH_REDACTED]/');
    sanitized = sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
    return sanitized.length <= maximumLength ? sanitized : '${sanitized.substring(0, maximumLength)}…';
  }

  /// 生成不关联设备的随机 UUID v4。
  String _randomUuid() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes.map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 安全取得对象字段 Map。
  Map<String, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value.map<String, Object?>((Object? key, Object? item) => key is String ? MapEntry<String, Object?>(key, item) : throw const FormatException('字段无效')) : <String, Object?>{};

  /// 安全取得非负整数。
  int _int(Object? value) => value is num && value >= 0 ? value.toInt() : 0;

  /// 将磁盘操作串行排队，前一项失败不会阻塞后续崩溃落盘。
  Future<void> _enqueue(Future<void> Function() operation) {
    final Future<void> scheduled = _pendingOperation
        .catchError((Object _) {})
        .then((_) => operation());
    _pendingOperation = scheduled.catchError((Object _) {});
    return scheduled;
  }
}
