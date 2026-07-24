import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api/remote_app/remote_app_api.dart';
import '../api/remote_app/remote_app_service_config.dart';
import '../data/dao/cache_dao.dart';
import '../domain/gateway/authentication_gateway.dart';
import '../domain/model/cache.dart';

/// 管理用户授权后的严格白名单匿名埋点桶和幂等上传。
final class AnalyticsRecorder {
  /// 创建匿名埋点记录器。
  AnalyticsRecorder(
    this._api,
    this._cacheDao,
    this._authenticationGateway,
    this._config,
  );

  /// 远端 App API。
  final RemoteAppApi _api;

  /// 通用缓存 DAO；队列继续复用既有 `caches` 表。
  final CacheDao _cacheDao;

  /// 当前认证会话边界。
  final AuthenticationGateway _authenticationGateway;

  /// 集中版本名、构建号和平台配置。
  final RemoteAppServiceConfig _config;

  /// 用户授权缓存键。
  static const String _consentCacheKey =
      'remote_app_analytics_consent_v1';

  /// 新协议埋点队列键；旧 v1 载荷不能安全迁移 eventId。
  static const String _queueCacheKey =
      'remote_app_analytics_queue_v2';

  /// 旧协议队列键；旧记录缺少幂等字段，首次访问授权状态时直接清理。
  static const String _legacyQueueCacheKey =
      'remote_app_analytics_queue_v1';

  /// 单批事件桶数量上限。
  static const int _maximumBatchSize = 50;

  /// 完整 UTF-8 请求体大小上限。
  static const int _maximumPayloadBytes = 16 * 1024;

  /// 本地有界队列上限。
  static const int _maximumQueueSize = 1000;

  /// 串行化队列读改写和 flush，避免并发覆盖新事件。
  Future<void> _operationTail = Future<void>.value();

  /// 合并短时间内连续产生的事件，避免在线状态下每个事件单独发请求。
  Timer? _flushTimer;

  /// 避免同一进程重复访问旧队列缓存。
  bool _legacyQueueCleared = false;

  /// 后端允许的事件与属性字段。
  static const Map<String, Set<String>> _allowedProps =
      <String, Set<String>>{
        'app_session_started': <String>{'restoreState'},
        'app_session_restore_result': <String>{
          'result',
          'refreshAttempted',
        },
        'search_submitted': <String>{
          'enabledSourceCount',
          'historyUsed',
        },
        'search_completed': <String>{
          'result',
          'resultCount',
          'successSourceCount',
          'failedSourceCount',
          'durationBucket',
        },
        'book_detail_opened': <String>{'entry'},
        'book_added_to_shelf': <String>{'entry'},
        'reader_opened': <String>{
          'entry',
          'contentKind',
          'durationBucket',
        },
        'reader_open_failed': <String>{
          'failureKind',
          'contentKind',
        },
        'book_source_import_completed': <String>{
          'entry',
          'importedCount',
          'blockedCount',
          'invalidCount',
        },
        'remote_book_source_sync_completed': <String>{
          'result',
          'pageCount',
          'sourceCount',
          'durationBucket',
        },
        'book_source_change_completed': <String>{
          'migrationProgress',
          'migrationReadConfig',
          'warningCount',
        },
        'chapter_source_change_completed': <String>{
          'candidateCount',
          'durationBucket',
        },
        'reader_download_completed': <String>{
          'result',
          'chapterCount',
          'durationBucket',
        },
        'local_book_import_completed': <String>{
          'format',
          'result',
          'durationBucket',
        },
        'settings_analytics_changed': <String>{'enabled'},
        'crash_report_upload_result': <String>{
          'result',
          'duplicate',
        },
      };

  /// 固定耗时分桶。
  static const Set<String> _durationBuckets = <String>{
    'lt_1s',
    '1_3s',
    '3_10s',
    '10_30s',
    'gte_30s',
  };

  /// 固定失败分类。
  static const Set<String> _failureKinds = <String>{
    'network',
    'http_status',
    'decode',
    'rule',
    'permission',
    'cancelled',
    'unknown',
  };

  /// 返回用户是否主动允许匿名分析。
  Future<bool> isEnabled() async {
    if (!_legacyQueueCleared) {
      await _cacheDao.delete(_legacyQueueCacheKey);
      _legacyQueueCleared = true;
    }
    return (await _cacheDao.get(_consentCacheKey))?.value == 'true';
  }

  /// 保存授权；关闭时立即清队列且不记录 enabled=false。
  Future<void> setEnabled(bool enabled) async {
    if (!enabled) {
      _flushTimer?.cancel();
      _flushTimer = null;
    }
    await _serialize(() async {
      if (!_legacyQueueCleared) {
        await _cacheDao.delete(_legacyQueueCacheKey);
        _legacyQueueCleared = true;
      }
      await _cacheDao.upsert(
        Cache(
          key: _consentCacheKey,
          value: enabled ? 'true' : 'false',
        ),
      );
      if (!enabled) {
        await _cacheDao.delete(_queueCacheKey);
      }
    });
    if (enabled) {
      await recordEvent(
        'settings_analytics_changed',
        props: const <String, Object?>{'enabled': true},
      );
    }
  }

  /// 校验、聚合并持久化一个匿名事件；未授权时不产生任何记录。
  Future<void> recordEvent(
    String eventName, {
    Map<String, Object?> props = const <String, Object?>{},
  }) async {
    if (!await isEnabled()) {
      return;
    }
    final Map<String, Object?>? normalized =
        _validateAndNormalize(eventName, props);
    if (normalized == null) {
      return;
    }
    await _serialize(() async {
      final List<Map<String, Object?>> queue =
          _pruneExpired(await _readQueue());
      final DateTime now = DateTime.now().toUtc();
      final String propsSignature = jsonEncode(normalized);
      Map<String, Object?>? mergeTarget;
      for (final Map<String, Object?> event in queue.reversed) {
        final Object? rawOccurredAt = event['occurredAt'];
        final DateTime? occurredAt = rawOccurredAt is String
            ? DateTime.tryParse(rawOccurredAt)
            : null;
        final Object? eventProps = event['props'];
        if (occurredAt == null ||
            event['eventName'] != eventName ||
            event['appVersionName'] != _config.appVersionName ||
            event['appVersionCode'] != _config.appVersionCode ||
            event['platform'] != _platform ||
            eventProps is! Map<String, Object?> ||
            jsonEncode(eventProps) != propsSignature ||
            occurredAt.year != now.year ||
            occurredAt.month != now.month ||
            occurredAt.day != now.day ||
            occurredAt.hour != now.hour) {
          continue;
        }
        final int count = event['count'] is num
            ? (event['count'] as num).toInt()
            : 0;
        if (count < 9999) {
          mergeTarget = event;
        }
        break;
      }
      if (mergeTarget == null) {
        queue.add(<String, Object?>{
          'eventId': _createUuidV4(),
          'eventName': eventName,
          'occurredAt': now.toIso8601String(),
          'appVersionName': _config.appVersionName,
          'appVersionCode': _config.appVersionCode,
          'platform': _platform,
          'count': 1,
          'props': normalized,
        });
      } else {
        final int count = (mergeTarget['count'] as num).toInt();
        mergeTarget['count'] = count + 1;
      }
      if (queue.length > _maximumQueueSize) {
        queue.removeRange(0, queue.length - _maximumQueueSize);
      }
      await _saveQueue(queue);
    });
    _scheduleFlush();
  }

  /// 延迟刷新持久队列；应用异常退出时事件仍已落盘，下次登录继续上传。
  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 5), () {
      unawaited(flush());
    });
  }

  /// 使用当前会话串行上传埋点桶；失败保留队列。
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _serialize(() async {
      if (!await isEnabled()) {
        return;
      }
      final String? token = _authenticationGateway.currentToken();
      if (token == null || token.isEmpty) {
        return;
      }
      final List<Map<String, Object?>> queue =
          _pruneExpired(await _readQueue());
      await _saveQueue(queue);
      if (_containsFutureTimestamp(queue)) {
        return;
      }
      while (queue.isNotEmpty) {
        final List<Map<String, Object?>> batch = _takeBatch(queue);
        if (batch.isEmpty) {
          queue.removeAt(0);
          await _saveQueue(queue);
          continue;
        }
        final RemoteAnalyticsReceipt receipt;
        try {
          receipt = await _api.reportAnalyticsEvents(token, batch);
        } on Object {
          return;
        }
        if (receipt.accepted + receipt.duplicate != batch.length) {
          return;
        }
        queue.removeRange(0, batch.length);
        await _saveQueue(queue);
      }
    });
  }

  /// 校验事件名、字段白名单、类型、枚举和数量范围。
  Map<String, Object?>? _validateAndNormalize(
    String eventName,
    Map<String, Object?> props,
  ) {
    final Set<String>? allowedKeys = _allowedProps[eventName];
    if (allowedKeys == null ||
        props.length != allowedKeys.length ||
        props.keys.any((String key) => !allowedKeys.contains(key))) {
      return null;
    }
    final List<String> keys = props.keys.toList()..sort();
    final Map<String, Object?> normalized = <String, Object?>{};
    for (final String key in keys) {
      final Object? value = props[key];
      if (value is bool) {
        normalized[key] = value;
        continue;
      }
      if (value is num) {
        if (!value.isFinite || value < 0) {
          return null;
        }
        normalized[key] = value.toInt().clamp(0, 9999);
        continue;
      }
      if (value is! String || value.length > 64) {
        return null;
      }
      if (key == 'durationBucket' &&
          !_durationBuckets.contains(value)) {
        return null;
      }
      if (key == 'failureKind' && !_failureKinds.contains(value)) {
        return null;
      }
      normalized[key] = value;
    }
    return normalized;
  }

  /// 按条数和完整 UTF-8 请求体大小动态装包。
  List<Map<String, Object?>> _takeBatch(
    List<Map<String, Object?>> queue,
  ) {
    final List<Map<String, Object?>> batch = <Map<String, Object?>>[];
    for (final Map<String, Object?> event in queue) {
      if (batch.length >= _maximumBatchSize) {
        break;
      }
      final List<Map<String, Object?>> candidate =
          <Map<String, Object?>>[...batch, event];
      final int byteLength = utf8
          .encode(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'events': candidate,
            }),
          )
          .length;
      if (byteLength > _maximumPayloadBytes) {
        break;
      }
      batch.add(event);
    }
    return batch;
  }

  /// 丢弃超过服务端七天窗口或时间格式损坏的事件。
  List<Map<String, Object?>> _pruneExpired(
    List<Map<String, Object?>> queue,
  ) {
    final DateTime cutoff =
        DateTime.now().toUtc().subtract(const Duration(days: 7));
    return queue.where((Map<String, Object?> event) {
      final Object? rawOccurredAt = event['occurredAt'];
      final DateTime? occurredAt = rawOccurredAt is String
          ? DateTime.tryParse(rawOccurredAt)
          : null;
      return occurredAt != null && !occurredAt.toUtc().isBefore(cutoff);
    }).toList(growable: true);
  }

  /// 设备时间明显快于服务端容忍窗口时暂停整批上传，保留本地事件等待时间恢复。
  bool _containsFutureTimestamp(List<Map<String, Object?>> queue) {
    final DateTime futureLimit =
        DateTime.now().toUtc().add(const Duration(minutes: 5));
    return queue.any((Map<String, Object?> event) {
      final Object? rawOccurredAt = event['occurredAt'];
      final DateTime? occurredAt = rawOccurredAt is String
          ? DateTime.tryParse(rawOccurredAt)
          : null;
      return occurredAt != null && occurredAt.toUtc().isAfter(futureLimit);
    });
  }

  /// 从 v2 缓存恢复可用事件桶，损坏数据按空队列降级。
  Future<List<Map<String, Object?>>> _readQueue() async {
    final String? raw = (await _cacheDao.get(_queueCacheKey))?.value;
    if (raw == null) {
      return <Map<String, Object?>>[];
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<Object?>) {
        return <Map<String, Object?>>[];
      }
      final List<Map<String, Object?>> queue = <Map<String, Object?>>[];
      for (final Object? value in decoded) {
        if (value is! Map<Object?, Object?>) {
          continue;
        }
        final Map<String, Object?> event = <String, Object?>{};
        for (final MapEntry<Object?, Object?> entry in value.entries) {
          if (entry.key is String) {
            event[entry.key as String] = entry.value;
          }
        }
        final Object? rawProps = event['props'];
        Map<String, Object?>? normalizedProps;
        if (rawProps is Map<Object?, Object?>) {
          final Map<String, Object?> props = <String, Object?>{};
          for (final MapEntry<Object?, Object?> entry
              in rawProps.entries) {
            if (entry.key is String) {
              props[entry.key as String] = entry.value;
            }
          }
          final Object? eventName = event['eventName'];
          if (eventName is String) {
            normalizedProps = _validateAndNormalize(eventName, props);
          }
        }
        final Object? eventId = event['eventId'];
        final Object? occurredAt = event['occurredAt'];
        final Object? appVersionName = event['appVersionName'];
        final Object? appVersionCode = event['appVersionCode'];
        final Object? platform = event['platform'];
        final Object? count = event['count'];
        if (eventId is! String ||
            !_isUuidV4(eventId) ||
            occurredAt is! String ||
            appVersionName is! String ||
            appVersionCode is! num ||
            appVersionCode < 0 ||
            platform is! String ||
            !<String>{'android', 'ios'}.contains(platform) ||
            count is! num ||
            count < 1 ||
            count > 9999 ||
            normalizedProps == null) {
          continue;
        }
        event['appVersionCode'] = appVersionCode.toInt();
        event['count'] = count.toInt();
        event['props'] = normalizedProps;
        queue.add(event);
      }
      return queue;
    } on FormatException {
      return <Map<String, Object?>>[];
    }
  }

  /// 覆盖保存埋点队列。
  Future<void> _saveQueue(List<Map<String, Object?>> queue) {
    return _cacheDao.upsert(
      Cache(key: _queueCacheKey, value: jsonEncode(queue)),
    );
  }

  /// 校验持久队列中的 UUID v4，防止损坏事件永久阻塞严格后端批次。
  bool _isUuidV4(String value) {
    if (value.length != 36 ||
        value[8] != '-' ||
        value[13] != '-' ||
        value[18] != '-' ||
        value[23] != '-' ||
        value[14] != '4' ||
        !<String>{'8', '9', 'a', 'b'}.contains(value[19].toLowerCase())) {
      return false;
    }
    final String compact = value.replaceAll('-', '');
    return compact.length == 32 && int.tryParse(compact, radix: 16) != null;
  }

  /// 将一次队列操作排在前一操作完成后执行。
  Future<void> _serialize(Future<void> Function() operation) {
    final Completer<void> completer = Completer<void>();
    final Future<void> previous = _operationTail;
    _operationTail = completer.future;
    return () async {
      try {
        await previous;
      } on Object {
        // 前一操作失败不应永久阻断后续队列处理。
      }
      try {
        await operation();
      } finally {
        completer.complete();
      }
    }();
  }

  /// 返回后端允许的平台枚举。
  String get _platform => Platform.isIOS ? 'ios' : 'android';

  /// 使用系统安全随机数创建 UUID v4，作为服务端幂等键。
  String _createUuidV4() {
    final Random random = Random.secure();
    final List<int> bytes =
        List<int>.generate(16, (int index) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes
        .map((int value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
