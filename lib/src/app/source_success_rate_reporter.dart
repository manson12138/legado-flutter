import 'dart:async';
import 'dart:convert';

import '../api/remote_app/remote_app_api.dart';
import '../data/dao/cache_dao.dart';
import '../domain/gateway/authentication_gateway.dart';
import '../domain/model/book_source.dart';
import '../domain/model/cache.dart';

/// 聚合 search/toc/content 最终结果并按两阶段协议上报书源成功率。
final class SourceSuccessRateReporter {
  /// 创建书源成功率上报器。
  SourceSuccessRateReporter(
    this._api,
    this._cacheDao,
    this._authenticationGateway,
  );

  /// 远端 App API。
  final RemoteAppApi _api;

  /// 聚合桶持久化使用的通用缓存 DAO。
  final CacheDao _cacheDao;

  /// 当前登录会话和书源同步权限边界。
  final AuthenticationGateway _authenticationGateway;

  /// 新聚合协议队列键。
  static const String _queueCacheKey =
      'remote_app_book_source_stats_queue_v2';

  /// 旧逐条事件队列键；新协议无法无损迁移为按日聚合桶。
  static const String _legacyQueueCacheKey =
      'remote_app_book_source_event_queue_v1';

  /// 单批统计桶数量上限。
  static const int _maximumBatchSize = 50;

  /// 完整 UTF-8 请求体大小上限。
  static const int _maximumPayloadBytes = 96 * 1024;

  /// 本地有界桶数量。
  static const int _maximumQueueSize = 1000;

  /// 允许上报的最终业务阶段。
  static const Set<String> _eventTypes = <String>{
    'search',
    'toc',
    'content',
  };

  /// 按 URL 读取完整本地书源的回调，在 BookSourceRepository 创建后配置。
  Future<BookSource?> Function(String sourceUrl)? _sourceProvider;

  /// 串行化桶读改写和网络 flush。
  Future<void> _operationTail = Future<void>.value();

  /// 合并短时间内连续产生的书源结果，避免每次请求都单独上传。
  Timer? _flushTimer;

  /// 避免同一进程反复访问旧逐条队列。
  bool _legacyQueueCleared = false;

  /// 配置未知书源第二阶段使用的本地书源读取器。
  void configureSourceProvider(
    Future<BookSource?> Function(String sourceUrl) provider,
  ) {
    _sourceProvider = provider;
  }

  /// 将一次最终成功或失败聚合到 URL、事件类型和 UTC 日期桶。
  Future<void> recordOutcome({
    required String sourceUrl,
    required String eventType,
    required bool success,
  }) async {
    final String normalizedUrl = sourceUrl.trim();
    if (normalizedUrl.isEmpty ||
        !_eventTypes.contains(eventType) ||
        !_isSafeReportUrl(normalizedUrl)) {
      return;
    }
    await _serialize(() async {
      await _clearLegacyQueue();
      final List<Map<String, Object?>> queue =
          _pruneExpired(await _readQueue());
      final DateTime now = DateTime.now().toUtc();
      final String day =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      Map<String, Object?>? target;
      for (final Map<String, Object?> bucket in queue.reversed) {
        if (bucket['bookSourceUrl'] == normalizedUrl &&
            bucket['eventType'] == eventType &&
            bucket['day'] == day) {
          final int currentCount = success
              ? _readCount(bucket['successCount'])
              : _readCount(bucket['failCount']);
          if (currentCount < 9999) {
            target = bucket;
          }
          break;
        }
      }
      if (target == null) {
        queue.add(<String, Object?>{
          'bookSourceUrl': normalizedUrl,
          'eventType': eventType,
          'day': day,
          'successCount': success ? 1 : 0,
          'failCount': success ? 0 : 1,
          'occurredAt': DateTime.utc(
            now.year,
            now.month,
            now.day,
          ).toIso8601String(),
        });
      } else {
        final String countKey =
            success ? 'successCount' : 'failCount';
        target[countKey] = _readCount(target[countKey]) + 1;
      }
      if (queue.length > _maximumQueueSize) {
        queue.removeRange(0, queue.length - _maximumQueueSize);
      }
      await _saveQueue(queue);
    });
    _scheduleFlush();
  }

  /// 延迟刷新已持久化桶；登录动作仍会显式立即刷新。
  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 5), () {
      unawaited(flush());
    });
  }

  /// 已登录且具有同步权限时刷新聚合桶，失败不影响业务主链路。
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _serialize(() async {
      await _clearLegacyQueue();
      final session = _authenticationGateway.session.value;
      final String? token = _authenticationGateway.currentToken();
      if (session == null ||
          !session.permissions.canSyncBookSource ||
          token == null ||
          token.isEmpty) {
        return;
      }
      final List<Map<String, Object?>> queue =
          _pruneExpired(await _readQueue());
      await _saveQueue(queue);
      if (_containsFutureTimestamp(queue)) {
        return;
      }
      while (queue.isNotEmpty) {
        final List<Map<String, Object?>> batch = _takeReportBatch(queue);
        if (batch.isEmpty) {
          queue.removeAt(0);
          await _saveQueue(queue);
          continue;
        }
        final List<Map<String, Object?>> reports =
            batch.map(_toReport).toList(growable: false);
        final RemoteBookSourceStatsReceipt firstReceipt;
        try {
          firstReceipt = await _api.reportBookSourceStats(
            token,
            reports: reports,
          );
        } on Object {
          return;
        }
        final Set<String> missingUrls =
            firstReceipt.missingBookSourceUrls.toSet();
        if (missingUrls.any(
          (String url) => !batch.any(
            (Map<String, Object?> bucket) =>
                bucket['bookSourceUrl'] == url,
          ),
        )) {
          return;
        }
        final List<Map<String, Object?>> accepted = batch
            .where(
              (Map<String, Object?> bucket) =>
                  !missingUrls.contains(bucket['bookSourceUrl']),
            )
            .toList(growable: false);
        if (firstReceipt.acceptedReports != accepted.length ||
            firstReceipt.importedSources != 0) {
          return;
        }
        _removeSnapshots(queue, accepted);
        await _saveQueue(queue);
        if (missingUrls.isEmpty) {
          continue;
        }
        final Future<BookSource?> Function(String sourceUrl)? provider =
            _sourceProvider;
        if (provider == null) {
          return;
        }
        final List<Map<String, Object?>> missingBuckets = batch
            .where(
              (Map<String, Object?> bucket) =>
                  missingUrls.contains(bucket['bookSourceUrl']),
            )
            .toList(growable: false);
        final Map<String, Map<String, Object?>> shareableSources =
            <String, Map<String, Object?>>{};
        for (final String sourceUrl in missingUrls) {
          final BookSource? source = await provider(sourceUrl);
          if (source != null && _isShareable(source)) {
            shareableSources[sourceUrl] = _sourceToJson(source);
          }
        }
        /// 第二阶段按完整书源体积动态装包，避免多个大规则合并后永久卡住队首。
        final List<Map<String, Object?>> secondBuckets =
            <Map<String, Object?>>[];
        final List<Map<String, Object?>> bookSources =
            <Map<String, Object?>>[];
        final Set<String> includedSourceUrls = <String>{};
        for (final Map<String, Object?> bucket in missingBuckets) {
          final Object? rawSourceUrl = bucket['bookSourceUrl'];
          if (rawSourceUrl is! String) {
            continue;
          }
          final Map<String, Object?>? sourceJson =
              shareableSources[rawSourceUrl];
          if (sourceJson == null) {
            continue;
          }
          final List<Map<String, Object?>> candidateBuckets =
              <Map<String, Object?>>[...secondBuckets, bucket];
          final List<Map<String, Object?>> candidateSources =
              <Map<String, Object?>>[
                ...bookSources,
                if (!includedSourceUrls.contains(rawSourceUrl))
                  sourceJson,
              ];
          final int candidateBytes = utf8
              .encode(
                jsonEncode(<String, Object?>{
                  'reports':
                      candidateBuckets.map(_toReport).toList(growable: false),
                  'bookSources': candidateSources,
                }),
              )
              .length;
          if (candidateBytes > _maximumPayloadBytes) {
            if (secondBuckets.isEmpty) {
              return;
            }
            break;
          }
          secondBuckets.add(bucket);
          if (includedSourceUrls.add(rawSourceUrl)) {
            bookSources.add(sourceJson);
          }
        }
        if (secondBuckets.isEmpty) {
          return;
        }
        final List<Map<String, Object?>> secondReports =
            secondBuckets.map(_toReport).toList(growable: false);
        final RemoteBookSourceStatsReceipt secondReceipt;
        try {
          secondReceipt = await _api.reportBookSourceStats(
            token,
            reports: secondReports,
            bookSources: bookSources,
          );
        } on Object {
          return;
        }
        if (secondReceipt.missingBookSourceUrls.isNotEmpty ||
            secondReceipt.acceptedReports != secondBuckets.length ||
            secondReceipt.importedSources < 0 ||
            secondReceipt.importedSources > bookSources.length) {
          return;
        }
        _removeSnapshots(queue, secondBuckets);
        await _saveQueue(queue);
        if (shareableSources.length != missingUrls.length) {
          return;
        }
      }
    });
  }

  /// 按条数和第一阶段完整请求体字节限制装包。
  List<Map<String, Object?>> _takeReportBatch(
    List<Map<String, Object?>> queue,
  ) {
    final List<Map<String, Object?>> batch =
        <Map<String, Object?>>[];
    for (final Map<String, Object?> bucket in queue) {
      if (batch.length >= _maximumBatchSize) {
        break;
      }
      final List<Map<String, Object?>> candidate =
          <Map<String, Object?>>[...batch, bucket];
      final int byteLength = utf8
          .encode(
            jsonEncode(<String, Object?>{
              'reports':
                  candidate.map(_toReport).toList(growable: false),
            }),
          )
          .length;
      if (byteLength > _maximumPayloadBytes) {
        break;
      }
      batch.add(bucket);
    }
    return batch;
  }

  /// 将本地桶转换为 API report，不传本地辅助 day 字段。
  Map<String, Object?> _toReport(Map<String, Object?> bucket) {
    return <String, Object?>{
      'bookSourceUrl': bucket['bookSourceUrl'],
      'eventType': bucket['eventType'],
      'successCount': _readCount(bucket['successCount']),
      'failCount': _readCount(bucket['failCount']),
      'occurredAt': bucket['occurredAt'],
    };
  }

  /// 从当前队列扣除已上传快照；串行 flush 下新计数不会被覆盖。
  void _removeSnapshots(
    List<Map<String, Object?>> queue,
    List<Map<String, Object?>> snapshots,
  ) {
    for (final Map<String, Object?> snapshot in snapshots) {
      queue.remove(snapshot);
    }
  }

  /// 判断完整书源是否可以在未知书源第二阶段上传。
  bool _isShareable(BookSource source) {
    final Uri? uri = Uri.tryParse(source.bookSourceUrl);
    if (uri == null ||
        !<String>{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        _isPrivateHost(uri.host)) {
      return false;
    }
    final String sensitiveText =
        jsonEncode(_sourceToJson(source)).toLowerCase();
    return !<String>[
      'authorization',
      'cookie',
      'password',
      'access_token',
      'refresh_token',
      'bearer ',
    ].any(sensitiveText.contains);
  }

  /// 拒绝可能包含账号凭据或只在私网可访问的原始统计地址。
  bool _isSafeReportUrl(String sourceUrl) {
    final Uri? uri = Uri.tryParse(sourceUrl);
    if (uri == null ||
        !<String>{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        _isPrivateHost(uri.host)) {
      return false;
    }
    final Set<String> sensitiveQueryKeys = <String>{
      'authorization',
      'cookie',
      'password',
      'token',
      'access_token',
      'refresh_token',
    };
    return !uri.queryParameters.keys.any(
      (String key) => sensitiveQueryKeys.contains(key.toLowerCase()),
    );
  }

  /// 判断主机是否是本机或常见私网地址。
  bool _isPrivateHost(String host) {
    final String lowerHost = host.toLowerCase();
    final String normalized = lowerHost.endsWith('.')
        ? lowerHost.substring(0, lowerHost.length - 1)
        : lowerHost;
    if (normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized.startsWith('fc') ||
        normalized.startsWith('fd') ||
        normalized.startsWith('fe80:') ||
        normalized.endsWith('.local')) {
      return true;
    }
    final List<int>? ipv4 = _parseIpv4(normalized);
    if (ipv4 == null) {
      return false;
    }
    return ipv4[0] == 0 ||
        ipv4[0] == 10 ||
        ipv4[0] == 127 ||
        ipv4[0] >= 224 ||
        (ipv4[0] == 100 && ipv4[1] >= 64 && ipv4[1] <= 127) ||
        (ipv4[0] == 169 && ipv4[1] == 254) ||
        (ipv4[0] == 192 && ipv4[1] == 168) ||
        (ipv4[0] == 172 && ipv4[1] >= 16 && ipv4[1] <= 31);
  }

  /// 解析严格四段 IPv4；域名返回 null。
  List<int>? _parseIpv4(String host) {
    final List<String> parts = host.split('.');
    if (parts.length != 4) {
      return null;
    }
    final List<int> values = <int>[];
    for (final String part in parts) {
      final int? value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) {
        return null;
      }
      values.add(value);
    }
    return values;
  }

  /// 将可分享书源转换为后端导入可识别的 JSON。
  Map<String, Object?> _sourceToJson(BookSource source) {
    return <String, Object?>{
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceName': source.bookSourceName,
      'bookSourceGroup': source.bookSourceGroup,
      'bookSourceType': source.bookSourceType,
      'bookUrlPattern': source.bookUrlPattern,
      'customOrder': source.customOrder,
      'enabled': source.enabled,
      'enabledExplore': source.enabledExplore,
      'jsLib': source.jsLib,
      'enabledCookieJar': source.enabledCookieJar,
      'concurrentRate': source.concurrentRate,
      'header': source.header,
      'loginUrl': source.loginUrl,
      'loginUi': source.loginUi,
      'loginCheckJs': source.loginCheckJs,
      'coverDecodeJs': source.coverDecodeJs,
      'bookSourceComment': source.bookSourceComment,
      'variableComment': source.variableComment,
      'lastUpdateTime': source.lastUpdateTime,
      'respondTime': source.respondTime,
      'weight': source.weight,
      'exploreUrl': source.exploreUrl,
      'exploreScreen': source.exploreScreen,
      'ruleExplore': source.ruleExplore,
      'searchUrl': source.searchUrl,
      'ruleSearch': source.ruleSearch,
      'ruleBookInfo': source.ruleBookInfo,
      'ruleToc': source.ruleToc,
      'ruleContent': source.ruleContent,
      'ruleReview': source.ruleReview,
      'eventListener': source.eventListener,
      'customButton': source.customButton,
      'homepageModules': source.homepageModules,
    };
  }

  /// 丢弃超过服务端 31 天窗口或结构损坏的桶。
  List<Map<String, Object?>> _pruneExpired(
    List<Map<String, Object?>> queue,
  ) {
    final DateTime cutoff =
        DateTime.now().toUtc().subtract(const Duration(days: 31));
    return queue.where((Map<String, Object?> bucket) {
      final Object? value = bucket['occurredAt'];
      final DateTime? occurredAt =
          value is String ? DateTime.tryParse(value) : null;
      return occurredAt != null && !occurredAt.toUtc().isBefore(cutoff);
    }).toList(growable: true);
  }

  /// 设备时间超过服务端未来五分钟窗口时暂停刷新，避免整批被拒绝。
  bool _containsFutureTimestamp(List<Map<String, Object?>> queue) {
    final DateTime futureLimit =
        DateTime.now().toUtc().add(const Duration(minutes: 5));
    return queue.any((Map<String, Object?> bucket) {
      final Object? value = bucket['occurredAt'];
      final DateTime? occurredAt =
          value is String ? DateTime.tryParse(value) : null;
      return occurredAt != null && occurredAt.toUtc().isAfter(futureLimit);
    });
  }

  /// 从缓存恢复聚合桶，损坏值按空队列降级。
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
        final Map<String, Object?> bucket = <String, Object?>{};
        for (final MapEntry<Object?, Object?> entry in value.entries) {
          if (entry.key is String) {
            bucket[entry.key as String] = entry.value;
          }
        }
        final int successCount = _readCount(bucket['successCount']);
        final int failCount = _readCount(bucket['failCount']);
        final Object? sourceUrl = bucket['bookSourceUrl'];
        final Object? eventType = bucket['eventType'];
        if (sourceUrl is String &&
            _isSafeReportUrl(sourceUrl) &&
            eventType is String &&
            _eventTypes.contains(eventType) &&
            bucket['day'] is String &&
            bucket['occurredAt'] is String &&
            successCount >= 0 &&
            failCount >= 0 &&
            successCount + failCount > 0) {
          bucket['successCount'] = successCount;
          bucket['failCount'] = failCount;
          queue.add(bucket);
        }
      }
      return queue;
    } on FormatException {
      return <Map<String, Object?>>[];
    }
  }

  /// 将动态计数收窄到 API 允许范围。
  int _readCount(Object? value) {
    if (value is! num) {
      return 0;
    }
    return value.toInt().clamp(0, 9999);
  }

  /// 覆盖保存聚合桶。
  Future<void> _saveQueue(List<Map<String, Object?>> queue) {
    return _cacheDao.upsert(
      Cache(key: _queueCacheKey, value: jsonEncode(queue)),
    );
  }

  /// 首次使用新协议时清除无法补齐聚合日和计数语义的旧逐条队列。
  Future<void> _clearLegacyQueue() async {
    if (_legacyQueueCleared) {
      return;
    }
    await _cacheDao.delete(_legacyQueueCacheKey);
    _legacyQueueCleared = true;
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
        // 前一操作失败不应永久阻断后续桶处理。
      }
      try {
        await operation();
      } finally {
        completer.complete();
      }
    }();
  }
}
