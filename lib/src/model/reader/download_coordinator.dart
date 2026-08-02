import 'dart:async';
import 'dart:math' as math;

import '../../api/http/http_contract.dart';
import '../../api/js/script_context.dart';
import '../../data/dao/cache_dao.dart';
import '../../data/local/preferences/app_preferences_store.dart';
import '../../data/local/preferences/versioned_app_preference_migrator.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/chapter_gateway.dart';
import '../../domain/gateway/download_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/download_task.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import '../../platform/download_background_service.dart';
import '../web_book/book_search_coordinator.dart';
import '../web_book/change_source_coordinator.dart';
import '../web_book/standard_source_parser.dart';
import '../web_book/standard_source_service.dart';
import 'chapter_title_matcher.dart';

/// App 级单例离线下载队列调度器，对应 Android `CacheBook`/`CacheBookModel` 的第一批职责。
///
/// 与页面级 `create*Coordinator()` 工厂方法不同，本协调器由 [AppDependencies] 在
/// `create()` 时构造一次并长期持有——用户关闭下载面板或退出阅读器后，已入队的下载
/// 仍需要继续跑，直到应用进程退出为止。
///
/// Android 通过数据同步前台服务提升后台运行可靠性；iOS 只使用系统授予的有限后台窗口。
/// 任一平台进程被系统终止后，残留“运行中”任务会在下次打开应用时恢复为等待并续传。
final class DownloadCoordinator {
/// 创建离线下载队列调度器；由应用启动流程在数据库初始化完成后显式恢复残留任务。
  DownloadCoordinator({
    required DownloadGateway downloadGateway,
    required ChapterGateway chapterGateway,
    required BookshelfGateway bookshelfGateway,
    required BookSourceGateway bookSourceGateway,
    required ReaderCacheGateway cacheGateway,
    required StandardBookSourceService standardService,
    required ChangeSourceCoordinator automaticSourceCoordinator,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
    required DownloadBackgroundService backgroundService,
    required CacheDao cacheDao,
    required AppPreferencesStore preferencesStore,
    required Future<bool> Function() analyticsEnabled,
    required Future<void> Function(
      String eventName, {
      Map<String, Object?> props,
    }) analyticsRecorder,
    this.maxRetryCount = 5,
    this.minimumRequestInterval = const Duration(milliseconds: 1500),
    this.chapterRequestTimeout = const Duration(seconds: 45),
  }) : _downloadGateway = downloadGateway,
       _chapterGateway = chapterGateway,
       _bookshelfGateway = bookshelfGateway,
       _bookSourceGateway = bookSourceGateway,
       _cacheGateway = cacheGateway,
       _standardService = standardService,
       _automaticSourceCoordinator = automaticSourceCoordinator,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger,
       _backgroundService = backgroundService,
       _legacyCacheDao = cacheDao,
       _preferencesStore = preferencesStore,
       _maximumConcurrencyMigrator =
           VersionedAppPreferenceMigrator(preferencesStore),
       _analyticsEnabled = analyticsEnabled,
       _analyticsRecorder = analyticsRecorder;

  /// Android `CacheBook.maxDownloadConcurrency` 对齐的下载并发安全上限。
  static const int maximumConcurrencyLimit = 8;

  /// 用户未保存设置时使用的全局章节下载并发数。
  static const int defaultMaximumConcurrency = 5;

  /// 持久化全局章节下载并发数的新 MMKV 键。
  static const String _maximumConcurrencySettingKey =
      'download.maximum_concurrency.v1';

  /// 下载并发设置迁移版本键。
  static const String _maximumConcurrencyMigrationKey =
      'migration.download.maximum_concurrency.v1';

  /// 下载并发设置的旧 SQLite 键。
  static const String _legacyMaximumConcurrencySettingKey =
      'setting_download_maximum_concurrency';

  /// 单章最大自动重试次数，超过后转为失败状态并等待用户手动重试。
  final int maxRetryCount;

  /// 两次真实书源正文请求之间的最短间隔，降低连续访问触发站点风控的概率。
  final Duration minimumRequestInterval;

  /// 单次章节正文请求的硬超时，避免异常书源长期占用一个全局下载并发槽位。
  final Duration chapterRequestTimeout;

  /// 自动换源允许锁定候选的最终安全底线，任一相邻正文低于该值都会拒绝候选。
  static const double automaticSourceMinimumSimilarity = 0.7;

  /// 下载批次完成后调整书源分数使用的成功率分界线。
  static const double sourceSuccessRateThreshold = 0.8;

  /// 每一级最多进入详情、目录和相邻正文验证的候选数。
  static const int maximumAutomaticCandidatesPerStage = 3;

  /// 一次自动换源从开始读取候选到停止的全局耗时上限，避免对应下载任务长期占用并发槽位。
  static const Duration automaticSourceMaximumDuration = Duration(minutes: 3);

  /// 单个梯度搜索阶段的最长占用时间，为详情、目录和正文验证保留全局预算。
  static const Duration automaticSourceStageSearchTimeout = Duration(
    seconds: 45,
  );

  /// 自动换源由高置信度向安全底线逐级放宽的搜索漏斗，累计最多检查七十八个书源。
  static const List<_AutomaticSourceStage> _automaticSourceStages =
      <_AutomaticSourceStage>[
        _AutomaticSourceStage(sourceCount: 3, minimumSimilarity: 0.98),
        _AutomaticSourceStage(sourceCount: 5, minimumSimilarity: 0.95),
        _AutomaticSourceStage(sourceCount: 8, minimumSimilarity: 0.90),
        _AutomaticSourceStage(sourceCount: 12, minimumSimilarity: 0.85),
        _AutomaticSourceStage(sourceCount: 20, minimumSimilarity: 0.80),
        _AutomaticSourceStage(sourceCount: 30, minimumSimilarity: 0.70),
      ];

  /// 下载队列持久化边界。
  final DownloadGateway _downloadGateway;

  /// 目录读取边界，用于取得目标章节的 URL 和标题。
  final ChapterGateway _chapterGateway;

  /// 书架读取边界，用于取得目标书籍的来源书源。
  final BookshelfGateway _bookshelfGateway;

  /// 书源读取边界。
  final BookSourceGateway _bookSourceGateway;

  /// 正文缓存边界，下载成功的正文以永久缓存写入，与单章换源共用同一存储语义。
  final ReaderCacheGateway _cacheGateway;

  /// 普通书源正文网络与规则服务。
  final StandardBookSourceService _standardService;

  /// 固定单搜索 worker 的自动换源候选协调器，不修改书架主源。
  final ChangeSourceCoordinator _automaticSourceCoordinator;

  /// HTTP 取消令牌工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 【搜书诊断日志】项目统一日志接口，用于记录下载队列调度。
  final AppLogger _logger;

  /// Android 前台服务与 iOS 有限后台任务的统一平台边界。
  final DownloadBackgroundService _backgroundService;

  /// 只在首次迁移时读取旧下载并发值的 SQLite 缓存 DAO。
  final CacheDao _legacyCacheDao;

  /// 下载并发设置使用的 MMKV 存储边界。
  final AppPreferencesStore _preferencesStore;

  /// 下载并发设置逐键迁移器。
  final VersionedAppPreferenceMigrator _maximumConcurrencyMigrator;

  /// 只在用户已授权时创建批次计时器。
  final Future<bool> Function() _analyticsEnabled;

  /// 匿名下载完成事件写入边界。
  final Future<void> Function(
    String eventName, {
    Map<String, Object?> props,
  }) _analyticsRecorder;

  /// 当前进程中新建批次的有界计时器；恢复批次不补造不准确耗时。
  final Map<(String, int), Stopwatch> _analyticsBatchStopwatches =
      <(String, int), Stopwatch>{};

  /// 当前有效的全局章节下载并发数；配置尚未读出时安全地采用默认值。
  int _maximumConcurrency = defaultMaximumConcurrency;

  /// 同一次进程生命周期内唯一的配置读取任务，避免多个界面并发读取时产生竞态。
  Future<int>? _maximumConcurrencyLoad;

  /// 应用启动期唯一的下载恢复任务，避免重试启动流程重复创建调度扫描。
  Future<void>? _startFuture;

  /// 当前登录用户下载调度代次；账号切换时递增，使旧异步任务停止回写。
  int _userSessionGeneration = 0;

  /// 当前是否允许领取登录用户的下载任务。
  bool _userSessionActive = false;

  /// 在内置书源导入等启动数据库任务完成后恢复残留下载并开始调度。
  ///
  /// 调用方可重复调用；同一进程中始终复用首次恢复任务，避免和启动事务竞争 SQLite 连接。
  Future<void> start() {
    _userSessionActive = true;
    final int generation = _userSessionGeneration;
    return _startFuture ??= _recoverAndStart(generation);
  }

  /// 取消旧账号的网络与自动换源任务，并允许下个账号重新执行队列恢复。
  void invalidateUserSession() {
    _userSessionGeneration += 1;
    _userSessionActive = false;
    _startFuture = null;
    _pumping = false;
    _pumpAgain = false;
    _runningCount = 0;
    clearAnalyticsMeasurements();
    for (final MapEntry<String, HttpCancellationToken> entry
        in _activeTokens.entries) {
      _removedTaskKeys.add(entry.key);
      entry.value.cancel('登录用户已切换');
    }
    for (final MapEntry<String, BookSearchRun> entry
        in _activeSearchRuns.entries) {
      _removedTaskKeys.add(entry.key);
      entry.value.cancel();
    }
    unawaited(_backgroundService.stop());
  }

  /// 授权关闭或账号切换时立即释放尚未结算的批次计时器。
  void clearAnalyticsMeasurements() {
    for (final Stopwatch stopwatch in _analyticsBatchStopwatches.values) {
      stopwatch.stop();
    }
    _analyticsBatchStopwatches.clear();
  }

  /// 当前正在运行的章节任务数。
  int _runningCount = 0;

  /// 是否已有一次调度扫描正在进行。
  bool _pumping = false;

  /// 当前扫描期间是否又有新的调度请求到达，扫描结束后需要立即再来一轮。
  bool _pumpAgain = false;

  /// 当前正在执行网络请求的任务键与取消令牌。
  final Map<String, HttpCancellationToken> _activeTokens =
      <String, HttpCancellationToken>{};

  /// 当前正在执行自动换源搜索的任务键与运行句柄，供暂停和删除立即取消搜索。
  final Map<String, BookSearchRun> _activeSearchRuns =
      <String, BookSearchRun>{};

  /// 用户暂停期间被取消的任务键，阻止网络取消异常把任务误记为失败。
  final Set<String> _pausedTaskKeys = <String>{};

  /// 用户删除期间被取消的任务键，阻止晚到结果重新创建任务。
  final Set<String> _removedTaskKeys = <String>{};

  /// 最近一次真实书源请求开始时间，用于全局串行限速。
  DateTime? _lastNetworkRequestAt;

  /// 当前进程已经恢复的锁定候选预览，避免每章重复请求详情和目录。
  final Map<String, ChangeSourceCandidatePreview> _lockedPreviews =
      <String, ChangeSourceCandidatePreview>{};

  /// 当前有效的全局章节下载并发数。
  int get maximumConcurrency => _maximumConcurrency;

  /// 读取并修正持久化的下载并发设置；缺失或非法值均回退到默认的 5 个请求。
  Future<int> loadMaximumConcurrency() {
    return _maximumConcurrencyLoad ??= _loadMaximumConcurrency();
  }

  /// 保存全局下载并发设置；调整仅影响后续领取的任务，不会取消正在执行的请求。
  Future<void> setMaximumConcurrency(int value) async {
    /// 防止异常调用突破 Android 对齐的安全上限或写入零并发导致队列停滞。
    final int normalized = value.clamp(1, maximumConcurrencyLimit).toInt();
    await loadMaximumConcurrency();
    if (!_preferencesStore.writeInt(
      _maximumConcurrencySettingKey,
      normalized,
    )) {
      throw StateError('下载并发偏好写入失败');
    }
    _maximumConcurrency = normalized;
    _kick();
  }

  /// 从通用缓存恢复并发设置，并把损坏数据回写为可用的默认值。
  Future<int> _loadMaximumConcurrency() async {
    final AppPreferenceMigrationResult<int> result =
        await _maximumConcurrencyMigrator.migrate<int>(
      valueKey: _maximumConcurrencySettingKey,
      migrationVersionKey: _maximumConcurrencyMigrationKey,
      targetVersion: 1,
      readCurrentValue: () => _validMaximumConcurrency(
        _preferencesStore.readInt(_maximumConcurrencySettingKey),
      ),
      writeCurrentValue: (int value) =>
          _preferencesStore.writeInt(_maximumConcurrencySettingKey, value),
      readLegacyValue: () async =>
          (await _legacyCacheDao.get(_legacyMaximumConcurrencySettingKey))
              ?.value,
      decodeLegacyValue: (String rawValue) =>
          _validMaximumConcurrency(int.tryParse(rawValue)),
    );
    final int? migratedValue = result.value;
    final int normalized = migratedValue ?? defaultMaximumConcurrency;
    _maximumConcurrency = normalized;
    if (result.value == null &&
        !_preferencesStore.writeInt(
          _maximumConcurrencySettingKey,
          normalized,
        )) {
      throw StateError('下载并发默认偏好写入失败');
    }
    return normalized;
  }

  /// 将下载并发数限制到当前调度器支持的安全范围。
  int? _validMaximumConcurrency(int? value) {
    if (value == null ||
        value < 1 ||
        value > maximumConcurrencyLimit) {
      return null;
    }
    return value;
  }

  /// 观察一本书的下载任务，供面板展示实时状态。
  Stream<List<DownloadTask>> watchTasks(String bookUrl) {
    return _downloadGateway.watchTasks(bookUrl);
  }

  /// 观察一本书的自动换源开关、锁定候选和批次状态。
  Stream<DownloadBookState?> watchBookState(String bookUrl) {
    return _downloadGateway.watchBookState(bookUrl);
  }

  /// 开启或关闭一本书的自动换源下载；关闭不会改动书架主源。
  Future<void> setAutoChangeSource(String bookUrl, bool enabled) async {
    /// 当前持久状态；首次配置时创建默认状态。
    final DownloadBookState current =
        await _loadOrCreateBookState(bookUrl);
    if (!enabled) {
      _lockedPreviews.remove(bookUrl);
      for (final MapEntry<String, BookSearchRun> entry
          in _activeSearchRuns.entries) {
        if (entry.key.startsWith('$bookUrl\n')) {
          entry.value.cancel();
        }
      }
    }
    await _downloadGateway.upsertBookState(
      current.copyWith(
        autoChangeSource: enabled,
        clearLockedCandidate: !enabled,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 观察全部书籍下载任务，供独立管理页跨书汇总。
  Stream<List<DownloadTask>> watchAllTasks() {
    return _downloadGateway.watchAllTasks();
  }

  /// 读取一本书完整目录，供管理页把章节索引转换为标题。
  Future<List<BookChapter>> loadChapters(String bookUrl) {
    return _chapterGateway.getChapterList(bookUrl);
  }

  /// 把指定章节索引加入下载队列；已存在的任务会重新排队。
  Future<void> enqueueIndices(String bookUrl, List<int> chapterIndices) async {
    if (chapterIndices.isEmpty) {
      return;
    }
    /// 当前时间戳，作为全部新任务的初始更新时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 当前书已有任务，用于判断是否开始新的评分批次。
    final List<DownloadTask> existingTasks =
        await _downloadGateway.getTasks(bookUrl);
    /// 当前书是否仍有未结算或用户暂停的任务。
    final bool hasOpenBatch = existingTasks.any(
      (DownloadTask task) =>
          task.status == DownloadTaskStatus.waiting ||
          task.status == DownloadTaskStatus.running ||
          task.status == DownloadTaskStatus.paused,
    );
    /// 当前书持久下载状态。
    final DownloadBookState currentState =
        await _loadOrCreateBookState(bookUrl);
    /// 本次任务使用的批次编号。
    final int generation = hasOpenBatch
        ? currentState.generation
        : currentState.generation + 1;
    await _startAnalyticsMeasurement(bookUrl, generation);
    if (!hasOpenBatch) {
      _lockedPreviews.remove(bookUrl);
      await _downloadGateway.upsertBookState(
        currentState.copyWith(
          generation: generation,
          triedSourceUrls: const <String>{},
          scoredSourceUrls: const <String>{},
          clearLockedCandidate: true,
          updatedAt: now,
        ),
      );
    }
    /// 待写入的等待中任务。
    final List<DownloadTask> tasks = chapterIndices
        .map(
          (int index) => DownloadTask(
            bookUrl: bookUrl,
            chapterIndex: index,
            status: DownloadTaskStatus.waiting,
            generation: generation,
            updatedAt: now,
          ),
        )
        .toList(growable: false);
    await _downloadGateway.upsertTasks(tasks);
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '离线下载入队 bookId=${appLogDiagnosticId(bookUrl)} chapterCount=${tasks.length}',
    );
    _kick();
    unawaited(_refreshBackgroundService());
  }

  /// 重新排队一个失败或已完成的任务。
  Future<void> retryTask(String bookUrl, int chapterIndex) async {
    /// 当前书任务快照，用于保留来源尝试归因和批次编号。
    final List<DownloadTask> tasks = await _downloadGateway.getTasks(bookUrl);
    /// 当前章节已有任务；不存在时由当前书批次创建新任务。
    final DownloadTask? existing = tasks
        .where((DownloadTask task) => task.chapterIndex == chapterIndex)
        .firstOrNull;
    /// 当前书下载批次状态。
    final DownloadBookState state = await _loadOrCreateBookState(bookUrl);
    await _downloadGateway.upsertTask(
      existing?.copyWith(
            status: DownloadTaskStatus.waiting,
            retryCount: 0,
            clearError: true,
            clearSuccessfulSource: true,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ) ??
          DownloadTask(
            bookUrl: bookUrl,
            chapterIndex: chapterIndex,
            status: DownloadTaskStatus.waiting,
            generation: state.generation,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
    );
    _kick();
    unawaited(_refreshBackgroundService());
  }

  /// 重新排队全部失败任务，成功和暂停任务保持不变。
  Future<void> retryAllFailed() async {
    /// 全部下载任务快照。
    final List<DownloadTask> tasks = await _downloadGateway.getAllTasks();
    for (final DownloadTask task in tasks) {
      if (task.status == DownloadTaskStatus.failed) {
        await retryTask(task.bookUrl, task.chapterIndex);
      }
    }
  }

  /// 重新排队一本书的全部失败任务。
  Future<void> retryBookFailed(String bookUrl) async {
    /// 指定书籍全部下载任务。
    final List<DownloadTask> tasks =
        await _downloadGateway.getTasks(bookUrl);
    for (final DownloadTask task in tasks) {
      if (task.status == DownloadTaskStatus.failed) {
        await retryTask(task.bookUrl, task.chapterIndex);
      }
    }
  }

  /// 暂停全部等待或运行任务，并取消当前单个网络请求。
  Future<void> pauseAll() async {
    _pausedTaskKeys.addAll(_activeTokens.keys);
    _pausedTaskKeys.addAll(_activeSearchRuns.keys);
    for (final HttpCancellationToken token in _activeTokens.values) {
      token.cancel('用户暂停全部离线下载');
    }
    for (final BookSearchRun run in _activeSearchRuns.values) {
      run.cancel();
    }
    await _downloadGateway.pauseAll(DateTime.now().millisecondsSinceEpoch);
    await _refreshBackgroundService();
  }

  /// 恢复全部暂停任务并按当前全局并发上限继续调度。
  Future<void> resumeAll() async {
    await _downloadGateway.resumeAll(DateTime.now().millisecondsSinceEpoch);
    _kick();
    await _refreshBackgroundService();
  }

  /// 暂停一本书的等待或运行任务。
  Future<void> pauseBook(String bookUrl) async {
    for (final MapEntry<String, HttpCancellationToken> entry
        in _activeTokens.entries) {
      if (entry.key.startsWith('$bookUrl\n')) {
        _pausedTaskKeys.add(entry.key);
        entry.value.cancel('用户暂停本书离线下载');
      }
    }
    for (final MapEntry<String, BookSearchRun> entry
        in _activeSearchRuns.entries) {
      if (entry.key.startsWith('$bookUrl\n')) {
        _pausedTaskKeys.add(entry.key);
        entry.value.cancel();
      }
    }
    await _downloadGateway.pauseBook(
      bookUrl,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _refreshBackgroundService();
  }

  /// 恢复一本书的全部暂停任务。
  Future<void> resumeBook(String bookUrl) async {
    await _downloadGateway.resumeBook(
      bookUrl,
      DateTime.now().millisecondsSinceEpoch,
    );
    _kick();
    await _refreshBackgroundService();
  }

  /// 暂停指定章节任务。
  Future<void> pauseTask(String bookUrl, int chapterIndex) async {
    /// 指定章节任务的内部稳定键。
    final String taskKey = _taskKey(bookUrl, chapterIndex);
    /// 当前任务可能存在的网络取消令牌。
    final HttpCancellationToken? token = _activeTokens[taskKey];
    if (token != null) {
      _pausedTaskKeys.add(taskKey);
      token.cancel('用户暂停章节离线下载');
    }
    /// 当前任务可能存在的自动换源搜索运行句柄。
    final BookSearchRun? searchRun = _activeSearchRuns[taskKey];
    if (searchRun != null) {
      _pausedTaskKeys.add(taskKey);
      searchRun.cancel();
    }
    await _downloadGateway.pauseTask(
      bookUrl,
      chapterIndex,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _refreshBackgroundService();
  }

  /// 恢复单个暂停任务或重新排队失败任务。
  Future<void> resumeTask(String bookUrl, int chapterIndex) {
    return retryTask(bookUrl, chapterIndex);
  }

  /// 删除单章离线正文和任务；运行中的晚到结果会被忽略。
  Future<void> deleteTaskDownload(String bookUrl, int chapterIndex) async {
    /// 指定章节任务的内部稳定键。
    final String taskKey = _taskKey(bookUrl, chapterIndex);
    _removedTaskKeys.add(taskKey);
    _activeTokens[taskKey]?.cancel('用户删除章节离线下载');
    _activeSearchRuns[taskKey]?.cancel();
    /// 当前书完整目录。
    final List<BookChapter> chapters =
        await _chapterGateway.getChapterList(bookUrl);
    /// 与任务章节索引对应的目录项。
    final BookChapter? chapter = chapters
        .where((BookChapter item) => item.index == chapterIndex)
        .firstOrNull;
    if (chapter != null) {
      await _cacheGateway.removeChapterContent(bookUrl, chapter.url);
    }
    await _downloadGateway.removeTask(bookUrl, chapterIndex);
    if (!_activeTokens.containsKey(taskKey) &&
        !_activeSearchRuns.containsKey(taskKey)) {
      _removedTaskKeys.remove(taskKey);
    }
    await _refreshBackgroundService();
  }

  /// 删除一本书全部离线正文和任务，并取消该书当前请求。
  Future<void> deleteBookDownloads(String bookUrl) async {
    for (final MapEntry<String, HttpCancellationToken> entry
        in _activeTokens.entries) {
      if (entry.key.startsWith('$bookUrl\n')) {
        _removedTaskKeys.add(entry.key);
        entry.value.cancel('用户删除本书离线下载');
      }
    }
    for (final MapEntry<String, BookSearchRun> entry
        in _activeSearchRuns.entries) {
      if (entry.key.startsWith('$bookUrl\n')) {
        _removedTaskKeys.add(entry.key);
        entry.value.cancel();
      }
    }
    /// 当前书完整目录。
    final List<BookChapter> chapters =
        await _chapterGateway.getChapterList(bookUrl);
    /// 当前书全部章节 URL，用于一次批量删除正文缓存。
    final List<String> chapterUrls = chapters
        .map((BookChapter chapter) => chapter.url)
        .toList(growable: false);
    await _cacheGateway.removeChapterContents(bookUrl, chapterUrls);
    await _downloadGateway.clearBook(bookUrl);
    await _refreshBackgroundService();
  }

  /// 仅删除一本书的下载任务并取消仍在执行的请求；已经写入离线缓存的正文保持不变。
  Future<void> removeBookTasks(String bookUrl) async {
    for (final MapEntry<String, HttpCancellationToken> entry
        in _activeTokens.entries) {
      if (entry.key.startsWith('$bookUrl\n')) {
        _removedTaskKeys.add(entry.key);
        entry.value.cancel('用户仅删除本书下载任务');
      }
    }
    for (final MapEntry<String, BookSearchRun> entry
        in _activeSearchRuns.entries) {
      if (entry.key.startsWith('$bookUrl\n')) {
        _removedTaskKeys.add(entry.key);
        entry.value.cancel();
      }
    }
    await _downloadGateway.clearBook(bookUrl);
    await _refreshBackgroundService();
  }

  /// 应用启动后把残留“运行中”任务重置为“等待”，随后开始调度。
  Future<void> _recoverAndStart(int generation) async {
    try {
      await loadMaximumConcurrency();
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      await _downloadGateway.resetRunningToWaiting(DateTime.now().millisecondsSinceEpoch);
    } on Object catch (error, stackTrace) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '离线下载队列恢复失败',
        error: error,
      );
      _logger.debug(tag: bookReaderContentLogTag, message: stackTrace.toString());
    }
    if (_isUserSessionCurrent(generation)) {
      _kick();
      unawaited(_refreshBackgroundService());
    }
  }

  /// 请求调度器尝试领取更多等待中的任务。
  void _kick() {
    if (!_userSessionActive) {
      return;
    }
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    unawaited(_pump(_userSessionGeneration));
  }

  /// 在并发上限内持续领取等待中的任务并异步处理。
  Future<void> _pump(int generation) async {
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        while (_isUserSessionCurrent(generation) &&
            _runningCount < _maximumConcurrency) {
          /// 本轮领取到的下一个任务；队列为空时为空。
          final DownloadTask? task = await _claimNextTask(generation);
          if (task == null) {
            break;
          }
          _runningCount += 1;
          unawaited(_refreshBackgroundService());
          unawaited(
            _processTask(task, generation).whenComplete(() {
              if (_isUserSessionCurrent(generation)) {
                _runningCount -= 1;
                unawaited(
                  _evaluateBookScoreIfSettled(
                    task.bookUrl,
                    task.generation,
                  ),
                );
                _kick();
                unawaited(_refreshBackgroundService());
              }
            }),
          );
        }
      } while (_pumpAgain && _isUserSessionCurrent(generation));
    } finally {
      _pumping = false;
    }
  }

  /// 从全部等待或运行中的任务里领取第一个仍处于等待状态的任务并标记为运行中。
  ///
  /// 领取过程中不产生额外 await，同一调度器实例内不会出现两次领取同一任务的竞争。
  Future<DownloadTask?> _claimNextTask(int generation) async {
    /// 全部等待或运行中的任务快照。
    final List<DownloadTask> pending = await _downloadGateway.getPendingTasks();
    if (!_isUserSessionCurrent(generation)) {
      return null;
    }
    for (final DownloadTask task in pending) {
      if (task.status != DownloadTaskStatus.waiting) {
        continue;
      }
      /// 标记为运行中的任务。
      final DownloadTask running = task.copyWith(
        status: DownloadTaskStatus.running,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _downloadGateway.upsertTask(running);
      return running;
    }
    return null;
  }

  /// 执行单个章节下载：跳过已缓存或卷标题，否则拉取正文并写入永久缓存。
  Future<void> _processTask(DownloadTask task, int generation) async {
    /// 【搜书诊断日志】当前下载任务不可逆标识。
    final String taskId =
        '${appLogDiagnosticId(task.bookUrl)}#${task.chapterIndex}';
    /// 当前任务在内存取消映射中的稳定键。
    final String taskKey = _taskKey(task.bookUrl, task.chapterIndex);
    /// 随真实来源尝试持续更新的任务副本，异常时也能保留书源归因。
    DownloadTask workingTask = task;
    try {
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      /// 目标书籍事实。
      final Book? book = await _bookshelfGateway.getBook(task.bookUrl);
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      if (book == null) {
        _logger.warning(tag: bookReaderContentLogTag, message: '离线下载终止 taskId=$taskId reason=bookMissing');
        await _downloadGateway.removeTask(task.bookUrl, task.chapterIndex);
        return;
      }
      /// 目标书籍完整目录。
      final List<BookChapter> chapters = await _chapterGateway.getChapterList(task.bookUrl);
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      /// 目标章节；目录已变化导致索引失效时视为任务过期。
      BookChapter? chapter;
      for (final BookChapter candidate in chapters) {
        if (candidate.index == task.chapterIndex) {
          chapter = candidate;
          break;
        }
      }
      if (chapter == null) {
        _logger.warning(tag: bookReaderContentLogTag, message: '离线下载终止 taskId=$taskId reason=chapterMissing');
        await _downloadGateway.removeTask(task.bookUrl, task.chapterIndex);
        return;
      }
      if (chapter.isVolume) {
        await _markSuccess(task, generation: generation);
        return;
      }
      /// 当前时间戳，用于缓存有效期判断。
      final int now = DateTime.now().millisecondsSinceEpoch;
      /// 已存在的正文缓存，无论普通 7 天缓存还是既有永久缓存都视为已下载。
      final String? existing = await _cacheGateway.getChapterContent(book.bookUrl, chapter.url, now);
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      if (existing != null) {
        /// 用户显式下载动作把既有缓存升级为永久缓存，不再受 7 天有效期约束。
        await _cacheGateway.saveChapterContent(book.bookUrl, chapter.url, existing, 0);
        await _markSuccess(
          task,
          generation: generation,
          contentLength: existing.length,
        );
        return;
      }
      if (book.origin == 'loc_book') {
        /// 本地书没有网络正文缓存概念，交给阅读器本地内容服务按需读取即可。
        await _markSuccess(task, generation: generation);
        return;
      }
      /// 本次下载取消令牌。
      final HttpCancellationToken token = _cancellationTokenFactory();
      _activeTokens[taskKey] = token;
      /// 本次准备使用的锁定来源；未锁定时为书架当前主源。
      final DownloadBookState sourceState =
          await _loadOrCreateBookState(
        book.bookUrl,
        generation: generation,
      );
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      /// 在详情、目录或正文任一阶段失败时都可归因的预期书源 URL。
      final String expectedSourceUrl =
          sourceState.lockedSourceUrl ?? book.origin;
      workingTask = task.copyWith(
        attemptedSourceUrls: <String>{
          ...task.attemptedSourceUrls,
          expectedSourceUrl,
        },
      );
      await _downloadGateway.upsertTask(workingTask);
      /// 原书源或已锁定候选解析出的本章下载上下文。
      final _DownloadSourceContext? sourceContext =
          await _resolveDownloadSourceContext(
        book: book,
        originalChapters: chapters,
        originalChapter: chapter,
        cancellationToken: token,
      );
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      if (sourceContext == null) {
        await _markFailed(
          workingTask,
          generation: generation,
          reason: 'sourceMissing',
        );
        return;
      }
      /// 加入本次实际使用书源后的来源归因集合。
      final Set<String> attemptedSourceUrls = <String>{
        ...workingTask.attemptedSourceUrls,
        sourceContext.source.bookSourceUrl,
      };
      workingTask = workingTask.copyWith(
        attemptedSourceUrls: attemptedSourceUrls,
      );
      await _downloadGateway.upsertTask(workingTask);
      await _waitForRequestSlot();
      /// 普通规则或 JavaScript 混合链路解析后的正文页。
      final ParsedContentPage parsed = await _loadContentWithTimeout(
        context: sourceContext,
        cancellationToken: token,
      );
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      if (parsed.content.trim().isEmpty) {
        await _markFailed(
          workingTask,
          generation: generation,
          reason: 'emptyContent',
        );
        return;
      }
      await _cacheGateway.saveChapterContent(book.bookUrl, chapter.url, parsed.content, 0);
      _logger.info(
        tag: bookReaderContentLogTag,
        message: '离线下载章节成功 taskId=$taskId contentLength=${parsed.content.length}',
      );
      await _markSuccess(
        workingTask,
        generation: generation,
        contentLength: parsed.content.length,
        successfulSourceUrl: sourceContext.source.bookSourceUrl,
      );
    } on Object catch (error, stackTrace) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '离线下载章节失败 taskId=$taskId retryCount=${task.retryCount}',
        error: error,
      );
      _logger.debug(tag: bookReaderContentLogTag, message: stackTrace.toString());
      await _markFailed(
        workingTask,
        generation: generation,
        reason: error is TimeoutException ? 'timeout' : 'exception',
      );
    } finally {
      _activeTokens.remove(taskKey);
    }
  }

  /// 把任务标记为下载成功。
  Future<void> _markSuccess(
    DownloadTask task, {
    required int generation,
    int contentLength = 0,
    String? successfulSourceUrl,
  }) {
    if (!_isUserSessionCurrent(generation)) {
      return Future<void>.value();
    }
    /// 当前任务在取消映射中的稳定键。
    final String taskKey = _taskKey(task.bookUrl, task.chapterIndex);
    if (_removedTaskKeys.remove(taskKey)) {
      return Future<void>.value();
    }
    if (_pausedTaskKeys.remove(taskKey)) {
      return _downloadGateway.upsertTask(
        task.copyWith(
          status: DownloadTaskStatus.paused,
          contentLength: contentLength,
          successfulSourceUrl: successfulSourceUrl,
          clearError: true,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return _downloadGateway.upsertTask(
      task.copyWith(
        status: DownloadTaskStatus.success,
        contentLength: contentLength,
        successfulSourceUrl: successfulSourceUrl,
        clearError: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 按重试次数决定短延迟后重新排队，或在达到上限后标记为失败终态。
  Future<void> _markFailed(
    DownloadTask task, {
    required int generation,
    required String reason,
  }) async {
    if (!_isUserSessionCurrent(generation)) {
      return;
    }
    /// 当前任务在取消映射中的稳定键。
    final String taskKey = _taskKey(task.bookUrl, task.chapterIndex);
    if (_removedTaskKeys.remove(taskKey)) {
      return;
    }
    if (_pausedTaskKeys.remove(taskKey)) {
      await _downloadGateway.upsertTask(
        task.copyWith(
          status: DownloadTaskStatus.paused,
          clearError: true,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    /// 本次失败后的累计重试次数。
    final int nextRetryCount = task.retryCount + 1;
    /// 可展示且不包含敏感请求数据的失败摘要。
    final String failureMessage = _failureMessage(reason);
    if (nextRetryCount >= maxRetryCount) {
      /// 达到五次失败后，仅在用户开启策略时尝试一次受控自动换源。
      final bool changedSource = await _tryAutomaticSource(task);
      if (!_isUserSessionCurrent(generation)) {
        return;
      }
      if (_removedTaskKeys.remove(taskKey)) {
        return;
      }
      if (_pausedTaskKeys.remove(taskKey)) {
        await _downloadGateway.upsertTask(
          task.copyWith(
            status: DownloadTaskStatus.paused,
            retryCount: nextRetryCount,
            errorMessage: failureMessage,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return;
      }
      if (changedSource) {
        await _downloadGateway.upsertTask(
          task.copyWith(
            status: DownloadTaskStatus.waiting,
            retryCount: 0,
            errorMessage: '已锁定验证通过的替代书源',
            clearSuccessfulSource: true,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return;
      }
      /// 自动换源结束后的最新书籍下载策略，用于区分普通失败和未找到合格来源。
      final DownloadBookState? automaticSourceState =
          await _downloadGateway.getBookState(task.bookUrl);
      /// 当前批次确实开启过自动换源但仍未锁定候选时展示的手动处理提示。
      final bool requiresManualSourceChange =
          automaticSourceState?.autoChangeSource == true &&
          automaticSourceState?.generation == task.generation;
      await _downloadGateway.upsertTask(
        task.copyWith(
          status: DownloadTaskStatus.failed,
          retryCount: nextRetryCount,
          errorMessage: requiresManualSourceChange
              ? '自动换源失败，请手动换源'
              : failureMessage,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    /// 指数退避秒数，限制在 2～10 秒，避免失败时快速重复访问书源。
    final int retryDelaySeconds = math.min(10, 2 << task.retryCount);
    await Future<void>.delayed(Duration(seconds: retryDelaySeconds));
    if (!_isUserSessionCurrent(generation)) {
      return;
    }
    if (_removedTaskKeys.remove(taskKey)) {
      return;
    }
    if (_pausedTaskKeys.remove(taskKey)) {
      await _downloadGateway.upsertTask(
        task.copyWith(
          status: DownloadTaskStatus.paused,
          retryCount: nextRetryCount,
          errorMessage: failureMessage,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    await _downloadGateway.upsertTask(
      task.copyWith(
        status: DownloadTaskStatus.waiting,
        retryCount: nextRetryCount,
        errorMessage: failureMessage,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 读取或创建一本书默认关闭自动换源的持久下载状态。
  Future<DownloadBookState> _loadOrCreateBookState(
    String bookUrl, {
    int? generation,
  }) async {
    /// 数据库已有的下载书籍状态。
    final DownloadBookState? existing =
        await _downloadGateway.getBookState(bookUrl);
    if (generation != null && !_isUserSessionCurrent(generation)) {
      throw StateError('登录用户已切换，旧下载状态读取已失效');
    }
    if (existing != null) {
      return existing;
    }
    /// 首次创建的默认安全状态。
    final DownloadBookState created = DownloadBookState(
      bookUrl: bookUrl,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _downloadGateway.upsertBookState(created);
    return created;
  }

  /// 判断异步下载工作是否仍属于当前已登录用户调度代次。
  bool _isUserSessionCurrent(int generation) {
    return _userSessionActive && _userSessionGeneration == generation;
  }

  /// 将原书源或已锁定替代来源解析为当前章节真实下载上下文。
  Future<_DownloadSourceContext?> _resolveDownloadSourceContext({
    required Book book,
    required List<BookChapter> originalChapters,
    required BookChapter originalChapter,
    required HttpCancellationToken cancellationToken,
  }) async {
    /// 当前书持久下载策略与锁定候选。
    final DownloadBookState state = await _loadOrCreateBookState(book.bookUrl);
    /// 已通过正文相似度验证的锁定候选。
    final SearchBook? lockedCandidate = state.lockedCandidate;
    if (lockedCandidate != null) {
      /// 当前进程缓存的锁定候选详情与目录。
      ChangeSourceCandidatePreview? preview = _lockedPreviews[book.bookUrl];
      preview ??= await _automaticSourceCoordinator
          .loadCandidate(
            candidate: lockedCandidate,
            cancellationToken: cancellationToken,
          )
          .timeout(
            chapterRequestTimeout,
            onTimeout: () {
              cancellationToken.cancel('锁定书源详情或目录请求超时');
              throw TimeoutException('锁定书源详情或目录请求超时');
            },
          );
      _lockedPreviews[book.bookUrl] = preview;
      /// 按原章节标题和目录比例定位候选来源中的目标章节索引。
      final int candidateIndex = resolveMatchingChapterIndex(
        oldChapterIndex: originalChapter.index,
        oldChapterTitle: originalChapter.title,
        newChapters: preview.chapters,
        oldChapterListSize: originalChapters.length,
      );
      /// 候选来源中实际用于下载的章节。
      final BookChapter? candidateChapter = preview.chapters
          .where((BookChapter chapter) => chapter.index == candidateIndex)
          .firstOrNull;
      /// 锁定候选当前仍存在的书源记录。
      final BookSource? candidateSource =
          await _bookSourceGateway.getByUrl(preview.book.origin);
      if (candidateChapter == null || candidateSource == null) {
        return null;
      }
      return _DownloadSourceContext(
        source: candidateSource,
        book: preview.book,
        chapter: candidateChapter,
        nextChapterUrl: _nextChapterUrl(
          preview.chapters,
          candidateChapter.index,
        ),
      );
    }
    /// 未开启或尚未锁定替代来源时使用书架当前主书源。
    final BookSource? source = await _bookSourceGateway.getByUrl(book.origin);
    if (source == null) {
      return null;
    }
    return _DownloadSourceContext(
      source: source,
      book: book,
      chapter: originalChapter,
      nextChapterUrl: _nextChapterUrl(
        originalChapters,
        originalChapter.index,
      ),
    );
  }

  /// 在硬超时内拉取一个章节正文，自动换源可传入更短的剩余全局时限。
  Future<ParsedContentPage> _loadContentWithTimeout({
    required _DownloadSourceContext context,
    required HttpCancellationToken cancellationToken,
    Duration? maximumDuration,
  }) {
    /// 本次请求最终允许使用的时长，不得突破章节硬超时和调用方剩余时限。
    final Duration requestTimeout = maximumDuration == null ||
            maximumDuration >= chapterRequestTimeout
        ? chapterRequestTimeout
        : maximumDuration;
    if (requestTimeout <= Duration.zero) {
      cancellationToken.cancel('离线章节请求已超过允许时限');
      throw TimeoutException('离线章节请求已超过允许时限');
    }
    return _standardService
        .loadContent(
          source: context.source,
          book: context.book,
          chapter: context.chapter,
          nextChapterUrl: context.nextChapterUrl,
          scriptOperation: LegadoScriptOperation.download,
          cancellationToken: cancellationToken,
        )
        .timeout(
          requestTimeout,
          onTimeout: () {
            cancellationToken.cancel('离线章节请求超时');
            throw TimeoutException('离线章节请求超时');
          },
        );
  }

  /// 读取指定章节的下一章 URL；目录末尾回退首章 URL 以保持原解析器既有边界。
  String? _nextChapterUrl(List<BookChapter> chapters, int chapterIndex) {
    /// 当前章节的下一章索引。
    final int nextChapterIndex = chapterIndex + 1;
    return chapters
            .where(
              (BookChapter chapter) => chapter.index == nextChapterIndex,
            )
            .firstOrNull
            ?.url ??
        chapters.firstOrNull?.url;
  }

  /// 五次失败后按六级梯度串行扩大搜索范围，并在达到当前相似度门槛时立即锁定。
  Future<bool> _tryAutomaticSource(DownloadTask task) async {
    try {
      /// 本轮自动换源无论书源多少都不能突破的绝对结束时间。
      final DateTime deadline = DateTime.now().add(
        automaticSourceMaximumDuration,
      );
      /// 当前失败任务的稳定键，用于感知用户在搜索期间发出的暂停或删除操作。
      final String taskKey = _taskKey(task.bookUrl, task.chapterIndex);
      /// 当前书下载策略。
      DownloadBookState state = await _loadOrCreateBookState(task.bookUrl);
      if (!state.autoChangeSource || state.generation != task.generation) {
        return false;
      }
      /// 当前书架书籍事实。
      final Book? book = await _bookshelfGateway.getBook(task.bookUrl);
      if (book == null || book.origin == 'loc_book') {
        return false;
      }
      /// 当前书原始目录，用于候选章节定位和相邻正文校验。
      final List<BookChapter> originalChapters =
          await _chapterGateway.getChapterList(task.bookUrl);
      /// 当前批次全部任务，用于寻找相邻已下载章节。
      final List<DownloadTask> batchTasks = (await _downloadGateway
              .getTasks(task.bookUrl))
          .where(
            (DownloadTask item) => item.generation == task.generation,
          )
          .toList(growable: false);
      /// 搜索前重新读取的最新开关和批次，防止前置目录读取期间用户已关闭自动换源。
      final DownloadBookState? stateBeforeSearch =
          await _downloadGateway.getBookState(task.bookUrl);
      if (stateBeforeSearch == null ||
          !stateBeforeSearch.autoChangeSource ||
          stateBeforeSearch.generation != task.generation) {
        return false;
      }
      /// 已尝试来源合并当前失败任务实际使用来源后的集合。
      Set<String> triedSourceUrls = <String>{
        ...stateBeforeSearch.triedSourceUrls,
        ...task.attemptedSourceUrls,
      };
      state = stateBeforeSearch.copyWith(
        triedSourceUrls: triedSourceUrls,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _downloadGateway.upsertBookState(state);
      /// 按置顶和成功率排序后的可参与自动搜索书源。
      final List<BookSource> enabledSources =
          await _automaticSourceCoordinator.loadEnabledSources();
      enabledSources.sort((BookSource left, BookSource right) {
        if (left.pinned != right.pinned) {
          return left.pinned ? -1 : 1;
        }
        return right.sourceScore.compareTo(left.sourceScore);
      });
      /// 排除本批已失败来源后的有序书源池；后续每一级只领取尚未搜索的新来源。
      final List<BookSource> availableSources = enabledSources
          .where(
            (BookSource source) =>
                !triedSourceUrls.contains(source.bookSourceUrl),
          )
          .toList(growable: false);
      if (availableSources.isEmpty) {
        return false;
      }
      /// 下一级从有序书源池开始领取的位置，确保梯度之间不会重复搜索同一来源。
      int nextSourceOffset = 0;
      /// 已完成正文校验且相邻正文均不低于最终 80% 底线的全部有限候选。
      final List<_AutomaticCandidateMatch> validatedMatches =
          <_AutomaticCandidateMatch>[];
      for (final _AutomaticSourceStage stage in _automaticSourceStages) {
        /// 每一级开始前重新读取开关，用户关闭后立即停止继续扩大来源范围。
        final DownloadBookState? latestState =
            await _downloadGateway.getBookState(task.bookUrl);
        if (latestState == null ||
            !latestState.autoChangeSource ||
            latestState.generation != task.generation) {
          return false;
        }
        state = latestState;
        if (_automaticSourceShouldStop(taskKey, deadline)) {
          return false;
        }
        /// 前一级候选在门槛降低后已经达标时直接锁定，不再访问更多书源。
        final _AutomaticCandidateMatch? retainedMatch =
            _bestAutomaticSourceMatch(
              validatedMatches,
              stage.minimumSimilarity,
            );
        if (retainedMatch != null) {
          return _persistAutomaticSourceLock(
            task: task,
            triedSourceUrls: triedSourceUrls,
            match: retainedMatch,
          );
        }
        /// 当前梯度新领取的有序书源；数量不足时只使用剩余来源。
        final List<BookSource> stageSources = availableSources
            .skip(nextSourceOffset)
            .take(stage.sourceCount)
            .toList(growable: false);
        nextSourceOffset += stageSources.length;
        if (stageSources.isEmpty) {
          break;
        }
        /// 当前梯度实际搜索的来源 URL 集合。
        final Set<String> selectedSourceUrls = stageSources
            .map((BookSource source) => source.bookSourceUrl)
            .toSet();
        /// 当前梯度收集的同名同作者候选；每个来源只保留第一个精确匹配结果。
        final Map<String, SearchBook> candidatesBySource =
            <String, SearchBook>{};
        /// 当前梯度已明确完成搜索、返回候选或报告失败的来源集合。
        final Set<String> completedSourceUrls = <String>{};
        /// 当前梯度自动换源单 worker 搜索运行句柄。
        final BookSearchRun run =
            await _automaticSourceCoordinator.startSearch(
              oldBook: book,
              checkAuthor: true,
              selectedSourceUrls: selectedSourceUrls,
              onEvent: (BookSearchEvent event) {
                switch (event) {
                  case BookSearchResultsEvent(
                    source: final BookSource source,
                    books: final List<SearchBook> books,
                  ):
                    completedSourceUrls.add(source.bookSourceUrl);
                    for (final SearchBook candidate in books) {
                      candidatesBySource.putIfAbsent(
                        candidate.origin,
                        () => candidate,
                      );
                    }
                  case BookSearchFailureEvent(
                    failure: final BookSearchSourceFailure failure,
                  ):
                    completedSourceUrls.add(failure.sourceUrl);
                  case BookSearchProgressEvent(
                    progress: final BookSearchProgress progress,
                  ):
                    if (progress.total > 0 &&
                        progress.completed >= progress.total) {
                      completedSourceUrls.addAll(selectedSourceUrls);
                    }
                }
              },
            );
        _activeSearchRuns[taskKey] = run;
        try {
          /// 搜索开始时的全流程剩余时长。
          final Duration remainingSearchDuration =
              _remainingAutomaticSourceDuration(
            deadline,
          );
          /// 当前梯度搜索时限，取阶段上限和全流程剩余时长中的较小值。
          final Duration searchTimeout =
              remainingSearchDuration < automaticSourceStageSearchTimeout
              ? remainingSearchDuration
              : automaticSourceStageSearchTimeout;
          if (searchTimeout <= Duration.zero) {
            run.cancel();
            return false;
          }
          await run.completion.timeout(
            searchTimeout,
            onTimeout: () {
              run.cancel();
              throw TimeoutException('自动换源当前梯度搜索超时');
            },
          );
          completedSourceUrls.addAll(selectedSourceUrls);
        } on Object {
          run.cancel();
        } finally {
          if (identical(_activeSearchRuns[taskKey], run)) {
            _activeSearchRuns.remove(taskKey);
          }
        }
        /// 搜索结束后的最新下载策略，防止旧状态覆盖用户刚关闭的自动换源开关。
        final DownloadBookState? stateAfterSearch =
            await _downloadGateway.getBookState(task.bookUrl);
        if (stateAfterSearch == null ||
            !stateAfterSearch.autoChangeSource ||
            stateAfterSearch.generation != task.generation) {
          return false;
        }
        /// 只持久化已经明确执行过的来源；阶段超时后尚未领取的来源允许下次继续尝试。
        triedSourceUrls = <String>{
          ...triedSourceUrls,
          ...completedSourceUrls,
        };
        state = stateAfterSearch.copyWith(
          triedSourceUrls: triedSourceUrls,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _downloadGateway.upsertBookState(state);
        if (_automaticSourceShouldStop(taskKey, deadline)) {
          return false;
        }
        /// 当前梯度按书源分数从高到低进入详情和正文验证的候选列表。
        final List<SearchBook> candidates = candidatesBySource.values.toList()
          ..sort(
            (SearchBook left, SearchBook right) =>
                right.sourceScore.compareTo(left.sourceScore),
          );
        for (final SearchBook candidate
            in candidates.take(maximumAutomaticCandidatesPerStage)) {
          if (_automaticSourceShouldStop(taskKey, deadline)) {
            break;
          }
          /// 当前候选详情、目录和相邻正文请求共用的取消令牌。
          final HttpCancellationToken token = _cancellationTokenFactory();
          _activeTokens[taskKey] = token;
          try {
            /// 当前候选详情与目录最多使用章节硬超时和全流程剩余时间中的较小值。
            final Duration candidateTimeout =
                _boundedAutomaticSourceOperationTimeout(deadline);
            /// 当前候选详情和完整目录预览。
            final ChangeSourceCandidatePreview preview =
                await _automaticSourceCoordinator
                    .loadCandidate(
                      candidate: candidate,
                      cancellationToken: token,
                    )
                    .timeout(
                      candidateTimeout,
                      onTimeout: () {
                        token.cancel('自动换源候选详情或目录超时');
                        throw TimeoutException('自动换源候选详情或目录超时');
                      },
                    );
            /// 相邻成功章节正文的最低值和平均值；任一正文低于 70% 时为空。
            final _AutomaticCandidateSimilarity? similarity =
                await _validateAutomaticCandidate(
                  task: task,
                  originalBook: book,
                  originalChapters: originalChapters,
                  batchTasks: batchTasks,
                  candidate: candidate,
                  preview: preview,
                  cancellationToken: token,
                  deadline: deadline,
                );
            if (similarity == null) {
              continue;
            }
            /// 合并详情阶段事实后的持久锁定候选。
            final SearchBook lockedCandidate = SearchBook(
              bookUrl: preview.book.bookUrl,
              origin: candidate.origin,
              originName: candidate.originName,
              name: preview.book.name,
              author: preview.book.author,
              type: preview.book.type,
              tocUrl: preview.book.tocUrl,
              variable: preview.book.variable,
              sourceScore: candidate.sourceScore,
              pinned: candidate.pinned,
            );
            /// 当前候选完整的锁定事实和相似度统计。
            final _AutomaticCandidateMatch match = _AutomaticCandidateMatch(
              lockedCandidate: lockedCandidate,
              preview: preview,
              averageSimilarity: similarity.averageSimilarity,
              minimumSimilarity: similarity.minimumSimilarity,
            );
            validatedMatches.add(match);
          } on Object catch (error) {
            _logger.warning(
              tag: bookReaderContentLogTag,
              message: '自动下载换源候选验证失败 '
                  'sourceId=${appLogDiagnosticId(candidate.origin)}',
              error: error,
            );
          } finally {
            if (identical(_activeTokens[taskKey], token)) {
              _activeTokens.remove(taskKey);
            }
          }
        }
        /// 当前梯度完成后使用最低相邻正文相似度执行门槛，任一相邻章不达标都不锁定。
        final _AutomaticCandidateMatch? stageMatch =
            _bestAutomaticSourceMatch(
              validatedMatches,
              stage.minimumSimilarity,
            );
        if (stageMatch != null) {
          return _persistAutomaticSourceLock(
            task: task,
            triedSourceUrls: triedSourceUrls,
            match: stageMatch,
          );
        }
      }
      return false;
    } on Object catch (error) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '自动下载换源失败 bookId=${appLogDiagnosticId(task.bookUrl)}',
        error: error,
      );
      return false;
    }
  }

  /// 用失败章节前后最近的已下载正文验证候选，并返回最低值与平均值供梯度判定。
  Future<_AutomaticCandidateSimilarity?> _validateAutomaticCandidate({
    required DownloadTask task,
    required Book originalBook,
    required List<BookChapter> originalChapters,
    required List<DownloadTask> batchTasks,
    required SearchBook candidate,
    required ChangeSourceCandidatePreview preview,
    required HttpCancellationToken cancellationToken,
    required DateTime deadline,
  }) async {
    /// 当前失败章节之前最近的成功任务。
    final DownloadTask? previousTask = batchTasks
        .where(
          (DownloadTask item) =>
              item.status == DownloadTaskStatus.success &&
              item.chapterIndex < task.chapterIndex,
        )
        .fold<DownloadTask?>(
          null,
          (DownloadTask? nearest, DownloadTask item) =>
              nearest == null || item.chapterIndex > nearest.chapterIndex
                  ? item
                  : nearest,
        );
    /// 当前失败章节之后最近的成功任务。
    final DownloadTask? nextTask = batchTasks
        .where(
          (DownloadTask item) =>
              item.status == DownloadTaskStatus.success &&
              item.chapterIndex > task.chapterIndex,
        )
        .fold<DownloadTask?>(
          null,
          (DownloadTask? nearest, DownloadTask item) =>
              nearest == null || item.chapterIndex < nearest.chapterIndex
                  ? item
                  : nearest,
        );
    /// 最多两个相邻成功章节，至少一个才允许验证候选。
    final List<DownloadTask> neighbors = <DownloadTask>[
      if (previousTask != null) previousTask,
      if (nextTask != null) nextTask,
    ];
    if (neighbors.isEmpty) {
      return null;
    }
    /// 实际完成正文比较的相邻章节数量。
    int comparedCount = 0;
    /// 已比较相邻章节相似度总和，用于候选间选择最高平均值。
    double similarityTotal = 0;
    /// 已比较相邻章节中的最低相似度，用于保证任一邻章都达到当前梯度门槛。
    double minimumSimilarity = 1;
    for (final DownloadTask neighborTask in neighbors) {
      if (_remainingAutomaticSourceDuration(deadline) <= Duration.zero) {
        cancellationToken.cancel('自动换源验证超过全局时限');
        throw TimeoutException('自动换源验证超过全局时限');
      }
      /// 原目录中与相邻任务对应的章节。
      final BookChapter? originalChapter = originalChapters
          .where(
            (BookChapter chapter) =>
                chapter.index == neighborTask.chapterIndex,
          )
          .firstOrNull;
      if (originalChapter == null) {
        continue;
      }
      /// 原书已下载的永久正文。
      final String? originalContent = await _cacheGateway.getChapterContent(
        originalBook.bookUrl,
        originalChapter.url,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (originalContent == null || originalContent.trim().isEmpty) {
        continue;
      }
      /// 候选目录中与原相邻章节最接近的索引。
      final int candidateIndex = resolveMatchingChapterIndex(
        oldChapterIndex: originalChapter.index,
        oldChapterTitle: originalChapter.title,
        newChapters: preview.chapters,
        oldChapterListSize: originalChapters.length,
      );
      /// 候选目录中实际比较正文的章节。
      final BookChapter? candidateChapter = preview.chapters
          .where((BookChapter chapter) => chapter.index == candidateIndex)
          .firstOrNull;
      /// 当前候选仍存在的书源记录。
      final BookSource? source =
          await _bookSourceGateway.getByUrl(candidate.origin);
      if (candidateChapter == null || source == null) {
        return null;
      }
      await _waitForRequestSlot();
      /// 请求间隔等待结束后的全流程剩余时长。
      final Duration remainingDuration = _remainingAutomaticSourceDuration(
        deadline,
      );
      /// 候选相邻章节解析后的正文。
      final ParsedContentPage parsed = await _loadContentWithTimeout(
        context: _DownloadSourceContext(
          source: source,
          book: preview.book,
          chapter: candidateChapter,
          nextChapterUrl: _nextChapterUrl(
            preview.chapters,
            candidateChapter.index,
          ),
        ),
        cancellationToken: cancellationToken,
        maximumDuration: remainingDuration,
      );
      /// 两个来源相邻章节正文的规范化 Jaccard 相似度。
      final double similarity = calculateChapterContentSimilarity(
        originalContent,
        parsed.content,
      );
      comparedCount += 1;
      if (similarity < automaticSourceMinimumSimilarity) {
        return null;
      }
      similarityTotal += similarity;
      minimumSimilarity = math.min(minimumSimilarity, similarity);
    }
    if (comparedCount == 0) {
      return null;
    }
    return _AutomaticCandidateSimilarity(
      averageSimilarity: similarityTotal / comparedCount,
      minimumSimilarity: minimumSimilarity,
    );
  }

  /// 判断自动换源是否因用户暂停、删除或全局耗时耗尽而必须停止。
  bool _automaticSourceShouldStop(String taskKey, DateTime deadline) {
    return _pausedTaskKeys.contains(taskKey) ||
        _removedTaskKeys.contains(taskKey) ||
        _remainingAutomaticSourceDuration(deadline) <= Duration.zero;
  }

  /// 计算自动换源全流程距离绝对结束时间仍可使用的时长。
  Duration _remainingAutomaticSourceDuration(DateTime deadline) {
    /// 当前时刻到绝对结束时间的差值，过期后统一收敛为零。
    final Duration remaining = deadline.difference(DateTime.now());
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  /// 计算候选详情或目录单次操作时限，不突破章节硬超时和全流程剩余时长。
  Duration _boundedAutomaticSourceOperationTimeout(DateTime deadline) {
    /// 当前自动换源全流程剩余时长。
    final Duration remaining = _remainingAutomaticSourceDuration(deadline);
    if (remaining <= Duration.zero) {
      throw TimeoutException('自动换源已超过全局时限');
    }
    return remaining < chapterRequestTimeout
        ? remaining
        : chapterRequestTimeout;
  }

  /// 从已验证候选中选择所有相邻正文均达到当前门槛且平均相似度最高的一项。
  _AutomaticCandidateMatch? _bestAutomaticSourceMatch(
    List<_AutomaticCandidateMatch> matches,
    double minimumSimilarity,
  ) {
    /// 当前门槛下已经选出的最佳候选。
    _AutomaticCandidateMatch? bestMatch;
    for (final _AutomaticCandidateMatch match in matches) {
      if (match.minimumSimilarity < minimumSimilarity) {
        continue;
      }
      /// 本轮比较前保留的最佳候选。
      final _AutomaticCandidateMatch? retained = bestMatch;
      if (retained == null || match.isBetterThan(retained)) {
        bestMatch = match;
      }
    }
    return bestMatch;
  }

  /// 持久化通过当前梯度的下载专用来源；开关或批次已变化时拒绝晚到锁定结果。
  Future<bool> _persistAutomaticSourceLock({
    required DownloadTask task,
    required Set<String> triedSourceUrls,
    required _AutomaticCandidateMatch match,
  }) async {
    /// 写入前重新读取的最新状态，防止用户关闭开关后晚到请求重新锁定来源。
    final DownloadBookState? latestState =
        await _downloadGateway.getBookState(task.bookUrl);
    if (latestState == null ||
        !latestState.autoChangeSource ||
        latestState.generation != task.generation) {
      return false;
    }
    /// 写入锁定来源和最新已尝试来源后的书籍下载状态。
    final DownloadBookState lockedState = latestState.copyWith(
      lockedCandidate: match.lockedCandidate,
      triedSourceUrls: triedSourceUrls,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _downloadGateway.upsertBookState(lockedState);
    _lockedPreviews[task.bookUrl] = match.preview;
    return true;
  }

  /// 当前批次全部任务终止后，按书源汇总成功章节占尝试章节比例并只评分一次。
  Future<void> _evaluateBookScoreIfSettled(
    String bookUrl,
    int generation,
  ) async {
    try {
      /// 当前书全部任务中的目标批次任务。
      final List<DownloadTask> tasks = (await _downloadGateway
              .getTasks(bookUrl))
          .where((DownloadTask task) => task.generation == generation)
          .toList(growable: false);
      if (tasks.isEmpty ||
          tasks.any(
            (DownloadTask task) =>
                task.status == DownloadTaskStatus.waiting ||
                task.status == DownloadTaskStatus.running ||
                task.status == DownloadTaskStatus.paused,
          )) {
        return;
      }
      /// 当前书下载批次状态。
      DownloadBookState state = await _loadOrCreateBookState(bookUrl);
      if (state.generation != generation) {
        return;
      }
      final Stopwatch? analyticsStopwatch =
          _analyticsBatchStopwatches.remove((bookUrl, generation));
      if (analyticsStopwatch != null) {
        analyticsStopwatch.stop();
        final int successCount = tasks
            .where(
              (DownloadTask task) =>
                  task.status == DownloadTaskStatus.success,
            )
            .length;
        final int failedCount = tasks
            .where(
              (DownloadTask task) =>
                  task.status == DownloadTaskStatus.failed,
            )
            .length;
        await _recordDownloadAnalytics(
          result: successCount == 0
              ? 'failed'
              : failedCount == 0
              ? 'success'
              : 'partial',
          chapterCount: tasks.length,
          elapsedMilliseconds: analyticsStopwatch.elapsedMilliseconds,
        );
      }
      /// 本批所有任务真实尝试过的书源集合。
      final Set<String> attemptedSources = tasks.fold<Set<String>>(
        <String>{},
        (Set<String> values, DownloadTask task) =>
            <String>{...values, ...task.attemptedSourceUrls},
      );
      /// 完成本次结算后的书源集合。
      final Set<String> scoredSources = <String>{...state.scoredSourceUrls};
      for (final String sourceUrl in attemptedSources) {
        if (scoredSources.contains(sourceUrl)) {
          continue;
        }
        /// 当前书源在本批实际尝试过的章节任务。
        final List<DownloadTask> sourceTasks = tasks
            .where(
              (DownloadTask task) =>
                  task.attemptedSourceUrls.contains(sourceUrl),
            )
            .toList(growable: false);
        /// 最终由当前书源成功提供正文的章节数量。
        final int successCount = sourceTasks
            .where(
              (DownloadTask task) =>
                  task.status == DownloadTaskStatus.success &&
                  task.successfulSourceUrl == sourceUrl,
            )
            .length;
        /// 当前书源在本书本批的下载成功率。
        final double successRate = sourceTasks.isEmpty
            ? 0
            : successCount / sourceTasks.length;
        if (successRate > sourceSuccessRateThreshold) {
          await _bookSourceGateway.recordSourceOutcome(sourceUrl, delta: 1);
        } else if (successRate < sourceSuccessRateThreshold) {
          await _bookSourceGateway.recordSourceOutcome(sourceUrl, delta: -1);
        }
        scoredSources.add(sourceUrl);
      }
      state = state.copyWith(
        scoredSourceUrls: scoredSources,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _downloadGateway.upsertBookState(state);
    } on Object catch (error) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '下载书源批次评分失败 bookId=${appLogDiagnosticId(bookUrl)}',
        error: error,
      );
    }
  }

  /// 已授权时为用户新建或扩展的当前批次保留一个有界计时器。
  Future<void> _startAnalyticsMeasurement(
    String bookUrl,
    int generation,
  ) async {
    try {
      if (!await _analyticsEnabled()) {
        return;
      }
      final (String, int) key = (bookUrl, generation);
      if (_analyticsBatchStopwatches.containsKey(key)) {
        return;
      }
      if (_analyticsBatchStopwatches.length >= 64) {
        final (String, int) oldest = _analyticsBatchStopwatches.keys.first;
        _analyticsBatchStopwatches.remove(oldest)?.stop();
      }
      _analyticsBatchStopwatches[key] = Stopwatch()..start();
    } on Object {
      // 授权读取失败不能阻止章节入队。
    }
  }

  /// 下载批次结算事件失败不影响既有书源评分或任务状态。
  Future<void> _recordDownloadAnalytics({
    required String result,
    required int chapterCount,
    required int elapsedMilliseconds,
  }) async {
    try {
      await _analyticsRecorder(
        'reader_download_completed',
        props: <String, Object?>{
          'result': result,
          'chapterCount': chapterCount,
          'durationBucket': _durationBucket(elapsedMilliseconds),
        },
      );
    } on Object {
      // 下载任务事实已持久化，匿名分析保持旁路。
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

  /// 等待全局请求间隔后记录本次真实书源请求开始时间。
  Future<void> _waitForRequestSlot() async {
    /// 上一次真实请求开始时间。
    final DateTime? previous = _lastNetworkRequestAt;
    if (previous != null) {
      /// 距离允许下次请求仍需等待的时间。
      final Duration remaining = minimumRequestInterval -
          DateTime.now().difference(previous);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    _lastNetworkRequestAt = DateTime.now();
  }

  /// 根据任务状态更新 Android 前台通知或 iOS 有限后台任务。
  Future<void> _refreshBackgroundService() async {
    try {
      /// 全部下载任务快照。
      final List<DownloadTask> tasks = await _downloadGateway.getAllTasks();
      /// 等待中的任务数量。
      final int waitingCount = tasks
          .where((DownloadTask task) =>
              task.status == DownloadTaskStatus.waiting)
          .length;
      /// 运行中的任务数量。
      final int runningCount = tasks
          .where((DownloadTask task) =>
              task.status == DownloadTaskStatus.running)
          .length;
      /// 暂停中的任务数量。
      final int pausedCount = tasks
          .where((DownloadTask task) =>
              task.status == DownloadTaskStatus.paused)
          .length;
      /// 成功任务数量。
      final int successCount = tasks
          .where((DownloadTask task) =>
              task.status == DownloadTaskStatus.success)
          .length;
      /// 失败任务数量。
      final int failedCount = tasks
          .where((DownloadTask task) =>
              task.status == DownloadTaskStatus.failed)
          .length;
      if (waitingCount == 0 && runningCount == 0) {
        await _backgroundService.stop();
        return;
      }
      await _backgroundService.startOrUpdate(
        waitingCount: waitingCount,
        runningCount: runningCount,
        pausedCount: pausedCount,
        successCount: successCount,
        failedCount: failedCount,
      );
    } on Object catch (error) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '下载后台状态更新失败',
        error: error,
      );
    }
  }

  /// 生成不写入日志的内存任务键。
  String _taskKey(String bookUrl, int chapterIndex) {
    return '$bookUrl\n$chapterIndex';
  }

  /// 将内部失败原因转换为不包含敏感数据的用户提示。
  String _failureMessage(String reason) {
    return switch (reason) {
      'sourceMissing' => '书源已不存在',
      'emptyContent' => '正文为空',
      'timeout' => '章节请求超时',
      _ => '网络或书源规则执行失败',
    };
  }
}

/// 一次真实章节下载使用的书源、候选书、候选章节和下一章地址。
final class _DownloadSourceContext {
  /// 创建已完成原书源或锁定候选解析的不可变下载上下文。
  const _DownloadSourceContext({
    required this.source,
    required this.book,
    required this.chapter,
    required this.nextChapterUrl,
  });

  /// 本次真实请求使用的书源。
  final BookSource source;

  /// 本次真实请求使用的原书或候选书事实。
  final Book book;

  /// 与原任务章节匹配后的真实请求章节。
  final BookChapter chapter;

  /// 候选目录中的下一章 URL；目录末尾允许为空或回退首章。
  final String? nextChapterUrl;
}

/// 描述自动换源漏斗中的一个阶段，只扫描指定数量的新书源并应用当前相似度门槛。
final class _AutomaticSourceStage {
  /// 创建不可变梯度阶段。
  const _AutomaticSourceStage({
    required this.sourceCount,
    required this.minimumSimilarity,
  });

  /// 当前阶段最多新增搜索的书源数量。
  final int sourceCount;

  /// 当前阶段要求每个已比较相邻章节达到的最低正文相似度。
  final double minimumSimilarity;
}

/// 保存候选相邻正文比较后的平均相似度与最低相似度。
final class _AutomaticCandidateSimilarity {
  /// 创建不可变候选相似度统计。
  const _AutomaticCandidateSimilarity({
    required this.averageSimilarity,
    required this.minimumSimilarity,
  });

  /// 所有已比较相邻章节的平均正文相似度，用于候选之间排序。
  final double averageSimilarity;

  /// 所有已比较相邻章节中的最低正文相似度，用于执行梯度安全门槛。
  final double minimumSimilarity;
}

/// 保存一个已经通过 70% 安全底线的候选来源、目录预览和相似度统计。
final class _AutomaticCandidateMatch {
  /// 创建可跨梯度保留的不可变候选匹配结果。
  const _AutomaticCandidateMatch({
    required this.lockedCandidate,
    required this.preview,
    required this.averageSimilarity,
    required this.minimumSimilarity,
  });

  /// 可持久化到下载书籍状态的候选搜索事实。
  final SearchBook lockedCandidate;

  /// 已完成详情和目录解析的候选预览。
  final ChangeSourceCandidatePreview preview;

  /// 所有已比较相邻章节的平均正文相似度。
  final double averageSimilarity;

  /// 所有已比较相邻章节中的最低正文相似度。
  final double minimumSimilarity;

  /// 判断当前候选是否应替换已保留候选，平均值优先、最低值作为同分安全兜底。
  bool isBetterThan(_AutomaticCandidateMatch other) {
    if (averageSimilarity != other.averageSimilarity) {
      return averageSimilarity > other.averageSimilarity;
    }
    return minimumSimilarity > other.minimumSimilarity;
  }
}
