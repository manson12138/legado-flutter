import 'dart:convert';

import '../api/remote_app/remote_app_api.dart';
import '../api/remote_app/remote_app_service_config.dart';
import '../data/dao/cache_dao.dart';
import '../data/local/preferences/app_preferences_store.dart';
import '../domain/gateway/authentication_gateway.dart';
import '../domain/model/book_source.dart';
import '../domain/model/book_source_import_result.dart';
import '../domain/model/cache.dart';
import '../domain/usecase/import_book_sources_use_case.dart';
import '../help/error/app_result.dart';
import '../help/logging/app_logger.dart';
import 'analytics_recorder.dart';
import 'source_success_rate_reporter.dart';

/// 服务器书源游标同步的可展示阶段；不携带 URL、游标或书源内容。
enum RemoteBookSourceSyncStage {
  /// 正在校验当前内存会话和服务器权限。
  checkingSession,
  /// 正在请求一个固定大小的服务端游标批次。
  fetchingBatch,
  /// 正在将当前批次交给既有导入事务。
  importingBatch,
}

/// API v2 游标同步的持久断点；仅在对应批次成功落库后前移。
final class _RemoteBookSourceCursorCheckpoint {
  /// 创建游标同步断点；空游标表示下一请求为首次请求。
  const _RemoteBookSourceCursorCheckpoint({
    this.beforeId,
    this.processedCount = 0,
    this.batchCount = 0,
    this.displayedTotal,
  });

  /// 与旧页码 checkpoint 隔离的缓存键，避免把旧状态误用于 API v2。
  static const String cacheKey = 'remote_book_source_cursor_sync_checkpoint_v2';

  /// 下一次请求使用的服务端游标；不向日志或 UI 暴露。
  final int? beforeId;
  /// 本轮已经成功提交导入事务的服务端条目数。
  final int processedCount;
  /// 本轮已经成功提交导入事务的批次数。
  final int batchCount;
  /// 最近一次响应的实时总数，仅用于进度展示。
  final int? displayedTotal;

  /// 从缓存 JSON 恢复并严格校验游标状态。
  factory _RemoteBookSourceCursorCheckpoint.fromJson(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('服务器书源同步断点格式无效');
    }
    final Object? cursorValue = decoded['beforeId'];
    final int? beforeId = cursorValue == null
        ? null
        : _readPositiveInt(cursorValue);
    final int? processedCount = _readNonNegativeInt(decoded['processedCount']);
    final int? batchCount = _readNonNegativeInt(decoded['batchCount']);
    final Object? totalValue = decoded['displayedTotal'];
    final int? displayedTotal = totalValue == null
        ? null
        : _readNonNegativeInt(totalValue);
    if ((cursorValue != null && beforeId == null) ||
        processedCount == null ||
        batchCount == null) {
      throw const FormatException('服务器书源同步断点字段无效');
    }
    return _RemoteBookSourceCursorCheckpoint(
      beforeId: beforeId,
      processedCount: processedCount,
      batchCount: batchCount,
      displayedTotal: displayedTotal,
    );
  }

  /// 序列化为通用缓存表可保存的 JSON。
  String toJson() => jsonEncode(<String, Object?>{
    'beforeId': beforeId,
    'processedCount': processedCount,
    'batchCount': batchCount,
    'displayedTotal': displayedTotal,
  });

  /// 读取严格为正的 JSON 整数。
  static int? _readPositiveInt(Object? value) {
    final int? number = _readNonNegativeInt(value);
    return number == null || number == 0 ? null : number;
  }

  /// 读取严格为非负的 JSON 整数，拒绝浮点数与字符串。
  static int? _readNonNegativeInt(Object? value) {
    return value is int && value >= 0 ? value : null;
  }
}

/// 书源同步进度；只传递批次与计数，避免 UI 持有远端敏感数据。
final class RemoteBookSourceSyncProgress {
  /// 创建可安全展示的同步进度快照。
  const RemoteBookSourceSyncProgress({
    required this.stage,
    this.batchNumber,
    this.processedCount = 0,
    this.totalCount,
  });

  /// 当前同步阶段。
  final RemoteBookSourceSyncStage stage;
  /// 当前批次序号，从一开始；不等同于服务端分页参数。
  final int? batchNumber;
  /// 当前轮已成功落库的远端条目数。
  final int processedCount;
  /// 服务端本次响应的实时总数，仅作展示。
  final int? totalCount;
}

/// 接收不含书源内容的同步进度快照。
typedef RemoteBookSourceSyncProgressListener =
    void Function(RemoteBookSourceSyncProgress progress);

/// 一次游标同步完成后的安全摘要。
final class RemoteBookSourceCursorSyncResult {
  /// 创建本轮同步结果。
  const RemoteBookSourceCursorSyncResult({
    required this.importedCount,
    required this.processedCount,
    required this.batchCount,
    required this.totalCount,
  });

  /// 本次运行中新增加或覆盖的本地书源数量。
  final int importedCount;
  /// 本轮从首次或断点开始成功落库的远端条目数量。
  final int processedCount;
  /// 本轮成功完成的批次数。
  final int batchCount;
  /// 最后一批响应的实时总数，仅作完成展示。
  final int totalCount;
}

/// 管理 App 会话、游标下载和既有书源导入事务的应用服务。
final class RemoteBookSourceSyncService {
  /// 创建服务器书源同步服务。
  RemoteBookSourceSyncService(
    this._api,
    CacheDao cacheDao,
    this._authenticationGateway,
    RemoteAppServiceConfig config,
    AppPreferencesStore preferencesStore,
    this._logger,
  ) : _cacheDao = cacheDao,
       _sourceSuccessRateReporter = SourceSuccessRateReporter(
         _api,
         cacheDao,
         _authenticationGateway,
       ),
       _analyticsRecorder = AnalyticsRecorder(
         _api,
         cacheDao,
         _authenticationGateway,
         config,
         preferencesStore,
       );

  /// 远端 App API。
  final RemoteAppApi _api;
  /// 当前认证会话与权限快照边界。
  final AuthenticationGateway _authenticationGateway;
  /// 统一诊断日志边界。
  final AppLogger _logger;
  /// 保存不含敏感数据的游标断点。
  final CacheDao _cacheDao;
  /// 书源成功率聚合与两阶段上报器。
  final SourceSuccessRateReporter _sourceSuccessRateReporter;
  /// 用户同意后的匿名埋点记录器。
  final AnalyticsRecorder _analyticsRecorder;
  /// 由组合根配置的既有书源导入事务。
  Future<AppResult<BookSourceImportResult>> Function(String sourceJson)? _batchImporter;
  /// 当前单飞同步任务，防止并发请求和导入互相覆盖断点。
  Future<RemoteBookSourceCursorSyncResult>? _activeSync;

  /// 清除当前认证会话，不影响本地书源和游标断点。
  void logout() => _authenticationGateway.logout();

  /// 配置成功率第二阶段读取本地完整书源所需的提供器。
  void configureBookSourceProvider(
    Future<BookSource?> Function(String sourceUrl) provider,
  ) {
    _sourceSuccessRateReporter.configureSourceProvider(provider);
  }

  /// 配置每批成功响应后复用的本地书源导入事务。
  void configurePageImporter(ImportBookSourcesUseCase importer) {
    _batchImporter = (String sourceJson) => importer.execute(
      sourceJson,
      conflictPolicy: BookSourceConflictPolicy.overwrite,
      /// 服务器同步需要完整保留服务器数据；可见性与搜索调度阶段再过滤。
      filterBlockedSources: false,
    );
  }

  /// 从已持久化游标继续同步；并发调用复用同一个任务而不重复导入。
  Future<RemoteBookSourceCursorSyncResult> syncAndImportSources({
    RemoteBookSourceSyncProgressListener? onProgress,
  }) {
    final Future<RemoteBookSourceCursorSyncResult>? activeSync = _activeSync;
    if (activeSync != null) {
      return activeSync;
    }
    late final Future<RemoteBookSourceCursorSyncResult> operation;
    operation = _runCursorSync(onProgress).whenComplete(() {
      if (identical(_activeSync, operation)) {
        _activeSync = null;
      }
    });
    _activeSync = operation;
    return operation;
  }

  /// 执行单个游标同步任务，并且仅在每批导入成功后推进断点。
  Future<RemoteBookSourceCursorSyncResult> _runCursorSync(
    RemoteBookSourceSyncProgressListener? onProgress,
  ) async {
    onProgress?.call(const RemoteBookSourceSyncProgress(
      stage: RemoteBookSourceSyncStage.checkingSession,
    ));
    final String? token = _authenticationGateway.currentToken();
    if (token == null || token.isEmpty) {
      _logger.warning(
        tag: remoteBookSourceSyncLogTag,
        message: 'stage=cursor_session_missing',
      );
      throw const FormatException('请先登录 App 账号');
    }
    if (_authenticationGateway.session.value?.permissions.canSyncBookSource != true) {
      _logger.warning(
        tag: remoteBookSourceSyncLogTag,
        message: 'stage=cursor_permission_missing',
      );
      throw const FormatException('当前账号没有服务器书源同步权限');
    }
    final Future<AppResult<BookSourceImportResult>> Function(String sourceJson)?
        importer = _batchImporter;
    if (importer == null) {
      throw StateError('服务器书源导入器尚未配置');
    }
    final _RemoteBookSourceCursorCheckpoint checkpoint = await _loadCheckpoint();
    int? beforeId = checkpoint.beforeId;
    int processedCount = checkpoint.processedCount;
    int batchCount = checkpoint.batchCount;
    int totalCount = checkpoint.displayedTotal ?? 0;
    int importedCount = 0;
    int invalidCount = 0;
    int blockedCount = 0;
    int pageCount = 0;
    int sourceCount = 0;
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      _logger.info(
        tag: remoteBookSourceSyncLogTag,
        message: 'stage=cursor_started batches=$batchCount processed=$processedCount',
      );
      while (true) {
        final int batchNumber = batchCount + 1;
        onProgress?.call(RemoteBookSourceSyncProgress(
          stage: RemoteBookSourceSyncStage.fetchingBatch,
          batchNumber: batchNumber,
          processedCount: processedCount,
          totalCount: totalCount == 0 ? null : totalCount,
        ));
        final RemoteBookSourceCursorPage page =
            await _api.fetchBookSourceCursorPage(token, beforeId: beforeId);
        _validatePage(page, beforeId);
        pageCount += 1;
        sourceCount += page.items.length;
        totalCount = page.total;
        onProgress?.call(RemoteBookSourceSyncProgress(
          stage: RemoteBookSourceSyncStage.importingBatch,
          batchNumber: batchNumber,
          processedCount: processedCount,
          totalCount: totalCount,
        ));
        if (page.items.isNotEmpty) {
          final AppResult<BookSourceImportResult> importResult =
              await importer(jsonEncode(page.items));
          final BookSourceImportResult batchResult = switch (importResult) {
            AppSuccess<BookSourceImportResult>(value: final BookSourceImportResult value) => value,
            AppFailure<BookSourceImportResult>(error: final Object error) => throw error,
          };
          importedCount += batchResult.imported;
          invalidCount += batchResult.invalid;
          blockedCount += batchResult.blockedAdult;
        }
        processedCount += page.items.length;
        batchCount = batchNumber;
        if (!page.hasMore) {
          await _cacheDao.delete(_RemoteBookSourceCursorCheckpoint.cacheKey);
          _logger.info(
            tag: remoteBookSourceSyncLogTag,
            message: 'stage=cursor_completed batches=$batchCount processed=$processedCount imported=$importedCount elapsedMs=${stopwatch.elapsedMilliseconds}',
          );
          await _recordAnalyticsBestEffort(
            'book_source_import_completed',
            props: <String, Object?>{
              'entry': 'remote_sync',
              'importedCount': importedCount,
              'blockedCount': blockedCount,
              'invalidCount': invalidCount,
            },
          );
          await _recordAnalyticsBestEffort(
            'remote_book_source_sync_completed',
            props: <String, Object?>{
              'result': 'success',
              'pageCount': pageCount,
              'sourceCount': sourceCount,
              'durationBucket': _durationBucket(
                stopwatch.elapsedMilliseconds,
              ),
            },
          );
          return RemoteBookSourceCursorSyncResult(
            importedCount: importedCount,
            processedCount: processedCount,
            batchCount: batchCount,
            totalCount: totalCount,
          );
        }
        beforeId = page.nextCursor;
        await _saveCheckpoint(_RemoteBookSourceCursorCheckpoint(
          beforeId: beforeId,
          processedCount: processedCount,
          batchCount: batchCount,
          displayedTotal: totalCount,
        ));
        _logger.info(
          tag: remoteBookSourceSyncLogTag,
          message: 'stage=cursor_batch_imported batch=$batchCount processed=$processedCount imported=$importedCount',
        );
      }
    } catch (error, stackTrace) {
      _logger.error(
        tag: remoteBookSourceSyncLogTag,
        message: 'stage=cursor_failed batches=$batchCount processed=$processedCount imported=$importedCount elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      await _recordAnalyticsBestEffort(
        'remote_book_source_sync_completed',
        props: <String, Object?>{
          'result': 'failed',
          'pageCount': pageCount,
          'sourceCount': sourceCount,
          'durationBucket': _durationBucket(stopwatch.elapsedMilliseconds),
        },
      );
      rethrow;
    }
  }

  /// 校验 API v2 批次控制字段，拒绝会导致跳过或循环的响应。
  void _validatePage(RemoteBookSourceCursorPage page, int? beforeId) {
    if (page.total < 0 || page.pageSize != 50) {
      throw const FormatException('服务器书源同步批次元数据无效');
    }
    if (page.items.isEmpty && page.hasMore) {
      throw const FormatException('服务器书源同步提前结束');
    }
    final int? nextCursor = page.nextCursor;
    if (page.hasMore && (nextCursor == null || nextCursor <= 0)) {
      throw const FormatException('服务器书源同步游标无效');
    }
    if (!page.hasMore && nextCursor != null) {
      throw const FormatException('服务器书源同步完成状态无效');
    }
    if (beforeId != null && nextCursor != null && nextCursor >= beforeId) {
      throw const FormatException('服务器书源同步游标未前进');
    }
  }

  /// 读取上次成功导入后保存的游标；损坏值只清除自身并从头开始。
  Future<_RemoteBookSourceCursorCheckpoint> _loadCheckpoint() async {
    final Cache? cache = await _cacheDao.get(
      _RemoteBookSourceCursorCheckpoint.cacheKey,
    );
    final String? value = cache?.value;
    if (value == null || value.isEmpty) {
      return const _RemoteBookSourceCursorCheckpoint();
    }
    try {
      return _RemoteBookSourceCursorCheckpoint.fromJson(value);
    } on FormatException catch (error) {
      _logger.warning(
        tag: remoteBookSourceSyncLogTag,
        message: 'stage=cursor_checkpoint_invalid',
        error: error,
      );
      await _cacheDao.delete(_RemoteBookSourceCursorCheckpoint.cacheKey);
      return const _RemoteBookSourceCursorCheckpoint();
    }
  }

  /// 在对应批次导入成功后，持久化下次请求使用的游标。
  Future<void> _saveCheckpoint(_RemoteBookSourceCursorCheckpoint checkpoint) {
    return _cacheDao.upsert(Cache(
      key: _RemoteBookSourceCursorCheckpoint.cacheKey,
      value: checkpoint.toJson(),
    ));
  }

  /// 记录书源一次最终成功或失败结果；失败只保留在本地成功率队列。
  Future<void> recordOutcome({
    required String sourceUrl,
    required String eventType,
    required bool success,
  }) async {
    await _sourceSuccessRateReporter.recordOutcome(
      sourceUrl: sourceUrl,
      eventType: eventType,
      success: success,
    );
  }

  /// 使用当前登录会话分批上传书源成功率队列。
  Future<void> flushPendingEvents() async {
    await _sourceSuccessRateReporter.flush();
  }

  /// 返回用户是否已明确允许匿名分析上报。
  Future<bool> isAnalyticsEnabled() => _analyticsRecorder.isEnabled();

  /// 保存分析同意状态；关闭后清理未发送队列。
  Future<void> setAnalyticsEnabled(bool enabled) async {
    await _analyticsRecorder.setEnabled(enabled);
  }

  /// 记录已同意的非敏感分析事件。
  Future<void> recordAnalyticsEvent(
    String eventName, {
    Map<String, Object?> props = const <String, Object?>{},
  }) async {
    await _analyticsRecorder.recordEvent(eventName, props: props);
  }

  /// 上传已同意的分析事件；失败保留队列等待后续会话。
  Future<void> flushPendingAnalytics() async {
    await _analyticsRecorder.flush();
  }

  /// 埋点写入失败只丢弃当前旁路动作，不改变书源同步结果。
  Future<void> _recordAnalyticsBestEffort(
    String eventName, {
    required Map<String, Object?> props,
  }) async {
    try {
      await _analyticsRecorder.recordEvent(eventName, props: props);
    } on Object {
      // 同步断点和导入事务拥有更高优先级。
    }
  }

  /// 将精确耗时转换为 API 固定分桶。
  String _durationBucket(int elapsedMilliseconds) {
    if (elapsedMilliseconds < 1000) {
      return 'lt_1s';
    }
    if (elapsedMilliseconds < 3000) {
      return '1_3s';
    }
    if (elapsedMilliseconds < 10000) {
      return '3_10s';
    }
    if (elapsedMilliseconds < 30000) {
      return '10_30s';
    }
    return 'gte_30s';
  }
}
