import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/gateway/search_history_gateway.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../app/search_preferences.dart';
import '../../help/logging/app_logger.dart';
import '../../model/web_book/book_search_coordinator.dart';
import 'search_contract.dart';

/// 管理多书源搜索、旧任务隔离、历史和页面 Effect 的 MVI ViewModel。
final class SearchViewModel {
  /// 创建 ViewModel 并读取启用书源与历史。
  SearchViewModel({
    required BookSearchCoordinator coordinator,
    required SearchHistoryGateway historyGateway,
    required SearchPreferences searchPreferences,
    required ValueListenable<int?> userScopeListenable,
    required Future<void> Function(
      String eventName, {
      Map<String, Object?> props,
    }) analyticsRecorder,
    required AppLogger logger,
  }) : _coordinator = coordinator,
       _historyGateway = historyGateway,
       _searchPreferences = searchPreferences,
       _userScopeListenable = userScopeListenable,
       _analyticsRecorder = analyticsRecorder,
       _logger = logger {
    _userScopeListenable.addListener(_handleUserScopeChanged);
    _bookSourceSubscription = _coordinator.watchSourceAvailability().listen(
      _applySourceAvailability,
      onError: _handleSourceStreamError,
    );
    _adultContentRuleSubscription = _coordinator.adultContentRuleChanges.listen(
      (int _) => unawaited(_refreshSourcesAfterAdultContentRuleChange()),
    );
    _initialize();
  }

  /// 多书源搜索协调器。
  final BookSearchCoordinator _coordinator;
  /// 搜索历史边界。
  final SearchHistoryGateway _historyGateway;
  /// 搜索匹配方式偏好边界，不保存用户查询内容。
  final SearchPreferences _searchPreferences;
  /// 当前本地用户作用域通知器，使保活搜索页能在认证恢复或账号切换后重读历史。
  final ValueListenable<int?> _userScopeListenable;
  /// 只接收协议白名单属性的匿名事件记录边界。
  final Future<void> Function(
    String eventName, {
    Map<String, Object?> props,
  }) _analyticsRecorder;
  /// 【搜书诊断日志】项目统一日志接口，不直接依赖具体输出实现。
  final AppLogger _logger;
  /// 当前页面状态。
  SearchUiState _state = SearchUiState();
  /// 状态广播流。
  final StreamController<SearchUiState> _stateController = StreamController<SearchUiState>.broadcast();
  /// Effect 广播流。
  final StreamController<SearchEffect> _effectController = StreamController<SearchEffect>.broadcast();
  /// 当前搜索运行句柄。
  BookSearchRun? _run;
  /// 书源可用性变化订阅，使保活搜索页能区分无书源、全停用和局部零选择。
  StreamSubscription<BookSearchSourceAvailability>? _bookSourceSubscription;
  /// 成人内容屏蔽规则变化监听，用于刷新保活页面中的书源和旧结果。
  StreamSubscription<int>? _adultContentRuleSubscription;
  /// 每次搜索递增的运行编号，用于拒绝旧回调污染新状态。
  int _generation = 0;
  /// 可用书源异步刷新代次，用于拒绝较慢的旧快照覆盖新规则结果。
  int _sourceLoadGeneration = 0;
  /// 搜索历史读取代次，用于拒绝游客或旧账号的较慢结果覆盖当前账号。
  int _historyLoadGeneration = 0;
  /// 按 Android 原始“书名 + 作者”键保存增量候选。
  final Map<String, List<SearchBook>> _resultBooks = <String, List<SearchBook>>{};

  /// 当前状态。
  SearchUiState get state => _state;
  /// 后续状态流。
  Stream<SearchUiState> get states => _stateController.stream;
  /// 一次性 Effect 流。
  Stream<SearchEffect> get effects => _effectController.stream;

  /// 搜索页面所有操作的唯一入口。
  void onIntent(SearchIntent intent) {
    switch (intent) {
      case ChangeSearchKeywordIntent(keyword: final String keyword):
        if (keyword.trim().isEmpty && _state.committedKeyword.isNotEmpty) {
          _clearSearch();
        } else {
          _emit(_state.copyWith(keyword: keyword, clearError: true));
        }
      case SubmitSearchIntent(keyword: final String? keyword):
        _submitSearch(keyword ?? _state.keyword);
      case CancelSearchIntent():
        _cancel(manual: true);
      case ResumeSearchAfterBookInfoIntent():
        _resumeAfterBookInfo();
      case RetryFailedSourcesIntent():
        /// 【搜书诊断日志】记录用户从失败书源区域触发重试。
        _logger.info(
          tag: bookSearchUiLogTag,
          message: '用户重试失败书源 failureCount=${_state.failures.length}',
        );
        _retryFailures();
      case ToggleSearchSourceIntent(sourceUrl: final String sourceUrl):
        _toggleSourceSelection(sourceUrl);
      case SelectAllSearchSourcesIntent():
        _emit(_state.copyWith(selectedSourceUrls: <String>{}, useAllSources: true));
      case ConfirmEnableAllSearchSourcesIntent():
        _confirmEnableAllSearchSources();
      case DismissEnableAllSearchSourcesIntent():
        _emit(
          _state.copyWith(clearPendingEnableAllSearchKeyword: true),
        );
      case InvertSearchSourcesIntent():
        _invertSources();
      case ApplySearchSourceSelectionIntent(
        selectedSourceUrls: final Set<String> selectedSourceUrls,
        useAllSources: final bool useAllSources,
        selectedSourceGroup: final String? selectedSourceGroup,
        sourceQuery: final String sourceQuery,
        onlySuccessfulSources: final bool onlySuccessfulSources,
      ):
        _emit(
          _state.copyWith(
            selectedSourceUrls: selectedSourceUrls,
            useAllSources: useAllSources,
            selectedSourceGroup: selectedSourceGroup,
            clearSelectedSourceGroup: selectedSourceGroup == null,
            sourceQuery: sourceQuery,
            onlySuccessfulSources: onlySuccessfulSources,
          ),
        );
      case ChangeSearchSourceGroupIntent(group: final String? group):
        _emit(_state.copyWith(selectedSourceGroup: group, clearSelectedSourceGroup: group == null));
      case ChangeSearchSourceQueryIntent(query: final String query):
        _emit(_state.copyWith(sourceQuery: query));
      case ToggleSuccessfulSearchSourcesIntent():
        _emit(_state.copyWith(onlySuccessfulSources: !_state.onlySuccessfulSources));
      case ChangeSearchMatchModeIntent(mode: final SearchMatchMode mode):
        _emit(_state.copyWith(matchMode: mode));
        _saveMatchMode(mode);
      case ClearSearchHistoryIntent():
        _clearHistory();
      case OpenSearchResultIntent(group: final BookSearchResultGroup group, book: final SearchBook book):
        _pauseForBookInfo();
        /// 【搜书诊断日志】记录点击的是哪个不可逆候选标识以及可换源数量。
        _logger.info(
          tag: bookSearchUiLogTag,
          message: '用户点击搜索结果 candidateCount=${group.books.length} '
              'bookId=${appLogDiagnosticId(book.bookUrl)} '
              'sourceId=${appLogDiagnosticId(book.origin)}',
        );
        _effectController.add(OpenBookInfoEffect(group, book));
      case BackFromSearchIntent():
        _effectController.add(const CloseSearchEffect());
    }
  }

  /// 读取搜索历史和匹配偏好；书源由独立观察流负责首次及后续加载。
  Future<void> _initialize() async {
    /// 本次初始化绑定的搜索历史读取代次。
    final int historyLoadGeneration = ++_historyLoadGeneration;
    /// 【搜书诊断日志】辅助状态初始化耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(tag: bookSearchUiLogTag, message: '搜索页面辅助状态初始化开始');
    try {
      /// 已保存历史。
      final List<String> history = await _historyGateway.load();
      /// 上次使用的结果匹配方式；不存在或无效值时保持默认模糊搜索。
      final String? savedMatchModeName = await _searchPreferences.readMatchModeName();
      if (_stateController.isClosed) {
        return;
      }
      /// 初始化期间用户作用域未改变时，历史才仍属于当前页面账号。
      final bool historyIsCurrent =
          historyLoadGeneration == _historyLoadGeneration;
      _emit(
        _state.copyWith(
          history: historyIsCurrent ? history : _state.history,
          matchMode: _matchModeFromName(savedMatchModeName),
        ),
      );
      _logger.info(
        tag: bookSearchUiLogTag,
        message: '搜索页面辅助状态初始化完成 '
            'historyCount=${historyIsCurrent ? history.length : _state.history.length} '
            'historyApplied=$historyIsCurrent '
            'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error, stackTrace) {
      if (historyLoadGeneration != _historyLoadGeneration ||
          _stateController.isClosed) {
        return;
      }
      _logger.error(
        tag: bookSearchUiLogTag,
        message: '搜索页面辅助状态初始化失败 elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(_state.copyWith(errorMessage: '读取搜索历史或偏好失败'));
    }
  }

  /// 用户作用域变化时清除旧账号的瞬时搜索状态，并为新作用域重新读取搜索历史。
  void _handleUserScopeChanged() {
    /// 新作用域搜索历史读取代次。
    final int historyLoadGeneration = ++_historyLoadGeneration;
    _generation += 1;
    _cancel(manual: false);
    _resultBooks.clear();
    _emit(
      _state.copyWith(
        keyword: '',
        committedKeyword: '',
        history: const <String>[],
        searching: false,
        cancelled: false,
        pausedForBookInfo: false,
        results: const <BookSearchResultGroup>[],
        failures: const <BookSearchSourceFailure>[],
        progress: const BookSearchProgress(
          total: 0,
          completed: 0,
          succeeded: 0,
          failed: 0,
        ),
        clearPendingEnableAllSearchKeyword: true,
        clearError: true,
      ),
    );
    _logger.info(
      tag: bookSearchUiLogTag,
      message: '用户作用域变化，重新读取搜索历史 '
          'historyLoadGeneration=$historyLoadGeneration',
    );
    unawaited(_reloadHistory(historyLoadGeneration));
  }

  /// 读取当前作用域的搜索历史，并拒绝账号再次变化后的旧结果。
  Future<void> _reloadHistory(int historyLoadGeneration) async {
    /// 当前作用域已保存的搜索历史。
    final List<String> history;
    try {
      history = await _historyGateway.load();
    } catch (error, stackTrace) {
      if (historyLoadGeneration != _historyLoadGeneration ||
          _stateController.isClosed) {
        return;
      }
      _logger.error(
        tag: bookSearchUiLogTag,
        message: '用户作用域变化后读取搜索历史失败 '
            'historyLoadGeneration=$historyLoadGeneration',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(_state.copyWith(errorMessage: '读取搜索历史失败'));
      return;
    }
    if (historyLoadGeneration != _historyLoadGeneration ||
        _stateController.isClosed) {
      return;
    }
    _emit(_state.copyWith(history: history, clearError: true));
    _logger.info(
      tag: bookSearchUiLogTag,
      message: '用户作用域变化后搜索历史读取完成 '
          'historyLoadGeneration=$historyLoadGeneration '
          'historyCount=${history.length}',
    );
  }

  /// 应用书源可用性观察流的新快照，并清理已经失效的临时选择条件。
  ///
  /// 当前搜索运行继续使用启动时的固定书源集合；这里只影响选择面板和下一次搜索。
  void _applySourceAvailability(
    BookSearchSourceAvailability availability,
  ) {
    if (_stateController.isClosed) {
      return;
    }
    /// 当前全局已启用且可见、可供搜索页选择的书源。
    final List<BookSource> sources = availability.enabledSources;
    /// 保留仍有效的旧选择，并让本次新增且可用的书源自动进入显式选择。
    final Set<String> selectedUrls = _selectedUrlsForSourceSnapshot(sources);
    /// 当前选中分组是否仍至少包含一个可用书源。
    final String? selectedGroup = _state.selectedSourceGroup;
    final bool clearSelectedGroup = selectedGroup != null &&
        !sources.any(
          (BookSource source) => _sourceHasGroup(source, selectedGroup),
        );
    _emit(
      _state.copyWith(
        loadingSources: false,
        visibleSourceCount: availability.visibleSourceCount,
        sources: sources,
        selectedSourceUrls: selectedUrls,
        clearSelectedSourceGroup: clearSelectedGroup,
        clearError: _state.errorMessage == '读取启用书源失败' ||
            _state.errorMessage == '刷新可用书源失败，请重试',
      ),
    );
  }

  /// 合并书源刷新前后的显式选择；新增且启用、可见的书源默认选中。
  ///
  /// “全部书源”状态由 [SearchUiState.useAllSources] 直接覆盖所有候选，无需展开 URL；
  /// 部分选择或零选择状态则保留仍有效的旧 URL，并只补入本次新增的可用 URL。
  Set<String> _selectedUrlsForSourceSnapshot(List<BookSource> sources) {
    /// 最新快照中可用于搜索的书源主键。
    final Set<String> visibleUrls = sources
        .map((BookSource source) => source.bookSourceUrl)
        .toSet();
    /// 移除已经删除、停用或被屏蔽的显式选择。
    final Set<String> selectedUrls =
        _state.selectedSourceUrls.intersection(visibleUrls);
    if (_state.useAllSources) {
      return selectedUrls;
    }
    /// 刷新前已经出现在搜索页中的可用书源主键。
    final Set<String> previousVisibleUrls = _state.sources
        .map((BookSource source) => source.bookSourceUrl)
        .toSet();
    selectedUrls.addAll(visibleUrls.difference(previousVisibleUrls));
    return selectedUrls;
  }

  /// 将书源观察流失败转换为页面可恢复错误，保留最后一次成功快照。
  void _handleSourceStreamError(Object error, StackTrace stackTrace) {
    if (_stateController.isClosed) {
      return;
    }
    _logger.error(
      tag: bookSearchUiLogTag,
      message: '搜索页监听启用书源失败',
      error: error,
      stackTrace: stackTrace,
    );
    _emit(
      _state.copyWith(
        errorMessage: '读取启用书源失败',
      ),
    );
  }

  /// 屏蔽开关或词库变化后取消旧搜索、清空旧结果并刷新可用书源快照。
  Future<void> _refreshSourcesAfterAdultContentRuleChange() async {
    /// 本次规则刷新对应的书源读取代次。
    final int sourceLoadGeneration = ++_sourceLoadGeneration;
    _generation += 1;
    _cancel(manual: false);
    _resultBooks.clear();
    _emit(
      _state.copyWith(
        loadingSources: true,
        searching: false,
        cancelled: false,
        pausedForBookInfo: false,
        results: const <BookSearchResultGroup>[],
        failures: const <BookSearchSourceFailure>[],
        progress: const BookSearchProgress(
          total: 0,
          completed: 0,
          succeeded: 0,
          failed: 0,
        ),
        clearPendingEnableAllSearchKeyword: true,
        clearError: true,
      ),
    );
    try {
      /// 按最新屏蔽开关、关键词和书源状态重新计算的书源可用性。
      final BookSearchSourceAvailability availability =
          await _coordinator.loadSourceAvailability();
      if (sourceLoadGeneration != _sourceLoadGeneration ||
          _stateController.isClosed) {
        return;
      }
      _applySourceAvailability(availability);
    } catch (error, stackTrace) {
      if (sourceLoadGeneration != _sourceLoadGeneration ||
          _stateController.isClosed) {
        return;
      }
      _logger.error(
        tag: bookSearchUiLogTag,
        message: '成人内容规则变化后刷新书源失败',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(
        _state.copyWith(
          loadingSources: false,
          errorMessage: '刷新可用书源失败，请重试',
        ),
      );
    }
  }

  /// 按书源事实优先级提交搜索，避免把无书源、全停用和局部零选择混为一谈。
  void _submitSearch(String rawKeyword) {
    /// 对话框与后续继续搜索共同使用的规范化关键字。
    final String keyword = rawKeyword.trim();
    if (keyword.isEmpty) {
      _logger.warning(
        tag: bookSearchUiLogTag,
        message: '搜索提交被拒绝 reason=emptyKeyword',
      );
      _effectController.add(const ShowSearchMessageEffect('请输入搜索关键字'));
      return;
    }
    if (_state.loadingSources) {
      _effectController.add(
        ShowSearchMessageEffect(
          _state.errorMessage == '读取启用书源失败'
              ? '读取启用书源失败'
              : '正在读取书源，请稍候',
        ),
      );
      return;
    }
    if (_state.visibleSourceCount == 0) {
      _effectController.add(
        const OpenBookSourceManagementEffect('当前没有书源，请添加书源'),
      );
      return;
    }
    if (_state.sources.isEmpty) {
      _effectController.add(
        const OpenBookSourceManagementEffect('当前没有开启的书源'),
      );
      return;
    }
    /// 搜索页分组、关键字、成功率与显式勾选共同解析出的执行集合。
    final Set<String> sourceUrls = _resolvedSelectedSourceUrls();
    if (sourceUrls.isEmpty) {
      _emit(
        _state.copyWith(pendingEnableAllSearchKeyword: keyword),
      );
      return;
    }
    _startSearch(keyword, sourceUrls: sourceUrls);
  }

  /// 恢复搜索页全部来源范围，并对书源快照复判后继续原提交关键字。
  void _confirmEnableAllSearchSources() {
    /// 对话框打开时固定的原提交关键字。
    final String? pendingKeyword = _state.pendingEnableAllSearchKeyword;
    if (pendingKeyword == null) {
      return;
    }
    _emit(
      _state.copyWith(
        selectedSourceUrls: <String>{},
        useAllSources: true,
        clearSelectedSourceGroup: true,
        sourceQuery: '',
        onlySuccessfulSources: false,
        clearPendingEnableAllSearchKeyword: true,
      ),
    );
    _submitSearch(pendingKeyword);
  }

  /// 开始新搜索并取消、隔离旧搜索。
  Future<void> _startSearch(String rawKeyword, {required Set<String> sourceUrls}) async {
    /// 去除首尾空白的关键字。
    final String keyword = rawKeyword.trim();
    if (keyword.isEmpty) {
      /// 【搜书诊断日志】空关键字在 ViewModel 边界被拒绝，没有创建搜索任务。
      _logger.warning(tag: bookSearchUiLogTag, message: '搜索提交被拒绝 reason=emptyKeyword');
      _effectController.add(const ShowSearchMessageEffect('请输入搜索关键字'));
      return;
    }
    /// 本次提交是否来自已有搜索历史，只记录布尔值而不上传搜索词。
    final bool historyUsed = _state.history.any(
      (String value) => value.trim() == keyword,
    );
    _recordAnalyticsEvent(
      'search_submitted',
      props: <String, Object?>{
        'enabledSourceCount': sourceUrls.length,
        'historyUsed': historyUsed,
      },
    );
    _cancel(manual: false);
    _generation += 1;
    /// 本次搜索固定运行编号。
    final int generation = _generation;
    /// 【搜书诊断日志】整次多书源搜索耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(
      tag: bookSearchUiLogTag,
      message: '搜索任务开始 generation=$generation keywordLength=${keyword.length} '
          'selectedSourceCount=${sourceUrls.length} allSources=${sourceUrls.isEmpty}',
    );
    _resultBooks.clear();
    _emit(
      _state.copyWith(
        keyword: keyword,
        committedKeyword: keyword,
        searching: true,
        cancelled: false,
        pausedForBookInfo: false,
        results: const <BookSearchResultGroup>[],
        failures: const <BookSearchSourceFailure>[],
        progress: BookSearchProgress(total: sourceUrls.isEmpty ? _state.sources.length : sourceUrls.length, completed: 0, succeeded: 0, failed: 0),
        clearError: true,
      ),
    );
    try {
      /// 提交搜索时捕获的历史作用域代次，防止账号切换后发布旧账号列表。
      final int historyLoadGeneration = _historyLoadGeneration;
      /// 写入并返回的新历史。
      final List<String> history = await _historyGateway.record(keyword);
      if (generation == _generation &&
          historyLoadGeneration == _historyLoadGeneration) {
        _emit(_state.copyWith(history: history));
        /// 【搜书诊断日志】只记录历史数量，不记录搜索词原文。
        _logger.debug(
          tag: bookSearchUiLogTag,
          message: '搜索历史已保存 generation=$generation historyCount=${history.length}',
        );
      }
      /// 新运行句柄。
      final BookSearchRun run = await _coordinator.start(
        keyword: keyword,
        selectedSourceUrls: sourceUrls,
        onEvent: (BookSearchEvent event) => _handleEvent(generation, event),
      );
      if (generation != _generation) {
        /// 【搜书诊断日志】启动阶段已经被更新任务替代，立即取消旧运行。
        _logger.warning(
          tag: bookSearchUiLogTag,
          message: '搜索任务启动后已过期 generation=$generation currentGeneration=$_generation',
        );
        run.cancel();
        return;
      }
      _run = run;
      await run.completion;
      if (identical(_run, run)) {
        _run = null;
      }
      if (generation == _generation && !run.isCancelled) {
        _emit(
          _state.copyWith(
            searching: false,
            pausedForBookInfo: false,
          ),
        );
        final BookSearchProgress progress = _state.progress;
        _recordAnalyticsEvent(
          'search_completed',
          props: <String, Object?>{
            'result': progress.succeeded == 0
                ? 'failed'
                : progress.failed == 0
                ? 'success'
                : 'partial',
            'resultCount': _state.results.length,
            'successSourceCount': progress.succeeded,
            'failedSourceCount': progress.failed,
            'durationBucket': _durationBucket(
              stopwatch.elapsedMilliseconds,
            ),
          },
        );
        _logger.info(
          tag: bookSearchUiLogTag,
          message: '搜索任务完成 generation=$generation groupCount=${_state.results.length} '
              'failureCount=${_state.failures.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
      }
    } catch (error, stackTrace) {
      if (generation == _generation) {
        _run = null;
        _logger.error(
          tag: bookSearchUiLogTag,
          message: '搜索任务启动或等待失败 generation=$generation '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(
          _state.copyWith(
            searching: false,
            pausedForBookInfo: false,
            errorMessage: '搜索任务启动失败',
          ),
        );
      }
    }
  }

  /// 进入书籍详情前暂停仍在运行的多书源任务，并保留结果和进度。
  void _pauseForBookInfo() {
    /// 当前可以被暂停的搜索运行句柄。
    final BookSearchRun? run = _run;
    if (!_state.searching || run == null || run.isCancelled || run.isPaused) {
      return;
    }
    run.pause();
    _emit(_state.copyWith(pausedForBookInfo: true));
  }

  /// 书籍详情和阅读链路全部离开后，从原进度恢复多书源任务。
  void _resumeAfterBookInfo() {
    /// 当前等待恢复的搜索运行句柄。
    final BookSearchRun? run = _run;
    if (!_state.pausedForBookInfo || run == null || run.isCancelled) {
      return;
    }
    run.resume();
    _emit(_state.copyWith(pausedForBookInfo: false));
  }

  /// 处理协调器事件，并用运行编号拒绝旧任务结果。
  void _handleEvent(int generation, BookSearchEvent event) {
    if (generation != _generation) {
      /// 【搜书诊断日志】旧搜索回调只记录隔离事实，不合并到当前页面。
      _logger.debug(
        tag: bookSearchUiLogTag,
        message: '忽略旧搜索事件 eventGeneration=$generation currentGeneration=$_generation '
            'eventType=${event.runtimeType}',
      );
      return;
    }
    switch (event) {
      case BookSearchResultsEvent(books: final List<SearchBook> books):
        _merge(books);
      case BookSearchFailureEvent(failure: final BookSearchSourceFailure failure):
        /// 【搜书诊断日志】单源详细错误由协调器记录，此处记录页面接收结果。
        _logger.warning(
          tag: bookSearchUiLogTag,
          message: '页面收到书源失败 generation=$generation '
              'sourceId=${appLogDiagnosticId(failure.sourceUrl)} category=${failure.category}',
        );
        _emit(_state.copyWith(failures: <BookSearchSourceFailure>[..._state.failures, failure]));
      case BookSearchProgressEvent(progress: final BookSearchProgress progress):
        /// 【搜书诊断日志】每个书源结束时输出可用于判断卡住位置的聚合进度。
        _logger.debug(
          tag: bookSearchUiLogTag,
          message: '搜索进度 generation=$generation completed=${progress.completed}/${progress.total} '
              'succeeded=${progress.succeeded} failed=${progress.failed}',
        );
        _emit(_state.copyWith(progress: progress));
    }
  }

  /// 按 Android 严格书名作者键合并来源，并按精确匹配和来源数排序。
  void _merge(List<SearchBook> books) {
    /// 【搜书诊断日志】合并前已有的结果组数量。
    final int previousGroupCount = _resultBooks.length;
    for (final SearchBook book in books) {
      if (!_matchesSearchMode(book)) {
        continue;
      }
      /// 避免拼接碰撞的内部键。
      final String key = '${book.name.length}:${book.name}${book.author}';
      /// 当前同名作者来源列表。
      final List<SearchBook> candidates = _resultBooks.putIfAbsent(key, () => <SearchBook>[]);
      if (!candidates.any((SearchBook value) => value.origin == book.origin && value.bookUrl == book.bookUrl)) {
        candidates.add(book);
      }
      /// 排序后 primary（books.first）始终是详情页的首选来源。
      candidates.sort(_compareSearchCandidates);
    }
    /// 不可变结果组。
    final List<BookSearchResultGroup> groups = _resultBooks.entries.map((entry) {
      return BookSearchResultGroup(key: entry.key, books: entry.value);
    }).toList(growable: false);
    groups.sort((BookSearchResultGroup left, BookSearchResultGroup right) {
      /// 左项是否精确匹配。
      final bool leftExact = left.primary.name.toLowerCase() == _state.committedKeyword.toLowerCase() || left.primary.author.toLowerCase() == _state.committedKeyword.toLowerCase();
      /// 右项是否精确匹配。
      final bool rightExact = right.primary.name.toLowerCase() == _state.committedKeyword.toLowerCase() || right.primary.author.toLowerCase() == _state.committedKeyword.toLowerCase();
      if (leftExact != rightExact) {
        return leftExact ? -1 : 1;
      }
      return right.books.length.compareTo(left.books.length);
    });
    _emit(_state.copyWith(results: groups));
    _logger.debug(
      tag: bookSearchUiLogTag,
      message: '搜索结果已合并 incomingBookCount=${books.length} '
          'previousGroupCount=$previousGroupCount currentGroupCount=${groups.length}',
    );
  }

  /// 将埋点作为非阻塞旁路执行，队列失败不改变搜索状态或错误提示。
  void _recordAnalyticsEvent(
    String eventName, {
    required Map<String, Object?> props,
  }) {
    unawaited(
      _analyticsRecorder(eventName, props: props).catchError((Object _) {}),
    );
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

  /// 将持久化枚举名称安全转换为搜索匹配方式。
  SearchMatchMode _matchModeFromName(String? name) {
    return switch (name) {
      'contains' => SearchMatchMode.contains,
      'exact' => SearchMatchMode.exact,
      'fuzzy' => SearchMatchMode.fuzzy,
      _ => SearchMatchMode.fuzzy,
    };
  }

  /// 异步保存匹配方式；保存失败不影响当前已经生效的搜索展示。
  Future<void> _saveMatchMode(SearchMatchMode mode) async {
    try {
      await _searchPreferences.saveMatchModeName(mode.name);
    } catch (_) {
      // 偏好写入失败只影响下次恢复，当前搜索仍以已发布状态继续执行。
    }
  }

  /// 将“全部、分组、书源名搜索、成功率”收敛为当前搜索的一次性候选集合。
  Set<String> _resolvedSelectedSourceUrls() {
    final String query = _state.sourceQuery.trim().toLowerCase();
    return _state.sources.where((BookSource source) {
      final String? group = _state.selectedSourceGroup;
      final bool matchesGroup = group == null || _sourceHasGroup(source, group);
      final bool matchesQuery = query.isEmpty ||
          source.bookSourceName.toLowerCase().contains(query) ||
          source.bookSourceUrl.toLowerCase().contains(query);
      return matchesGroup && matchesQuery &&
          (!_state.onlySuccessfulSources || source.sourceScore > 0) &&
          (_state.useAllSources || _state.selectedSourceUrls.contains(source.bookSourceUrl));
    }).map((BookSource source) => source.bookSourceUrl).toSet();
  }

  /// 判断逗号分隔的书源分组是否包含目标分组。
  bool _sourceHasGroup(BookSource source, String group) {
    return (source.bookSourceGroup ?? '').split(',').map((String value) => value.trim()).contains(group);
  }

  /// 切换单书源时先将“全部”展开为明确集合，避免空集合同时表达全部和未选。
  void _toggleSourceSelection(String sourceUrl) {
    final Set<String> selected = _state.useAllSources
        ? _state.sources.map((BookSource source) => source.bookSourceUrl).toSet()
        : Set<String>.from(_state.selectedSourceUrls);
    if (!selected.add(sourceUrl)) {
      selected.remove(sourceUrl);
    }
    _emit(_state.copyWith(selectedSourceUrls: selected, useAllSources: false));
  }

  /// 反选当前全部可用书源。
  void _invertSources() {
    final Set<String> all = _state.sources.map((BookSource source) => source.bookSourceUrl).toSet();
    final Set<String> current = _state.useAllSources ? all : _state.selectedSourceUrls;
    _emit(_state.copyWith(selectedSourceUrls: all.difference(current), useAllSources: false));
  }

  /// 根据用户选择筛掉不应显示的搜索结果。
  bool _matchesSearchMode(SearchBook book) {
    final String keyword = _state.committedKeyword.trim().toLowerCase();
    if (keyword.isEmpty || _state.matchMode == SearchMatchMode.fuzzy) {
      return true;
    }
    final String name = book.name.trim().toLowerCase();
    final String author = book.author.trim().toLowerCase();
    return _state.matchMode == SearchMatchMode.exact
        ? name == keyword || author == keyword
        : name.contains(keyword) || author.contains(keyword);
  }

  /// 按用户置顶、历史成功率和稳定书源顺序比较同组候选，避免并发搜索返回顺序影响首选来源。
  int _compareSearchCandidates(SearchBook left, SearchBook right) {
    if (left.pinned != right.pinned) {
      return left.pinned ? -1 : 1;
    }
    final int scoreOrder = right.sourceScore.compareTo(left.sourceScore);
    if (scoreOrder != 0) {
      return scoreOrder;
    }
    final int sourceOrder = left.originOrder.compareTo(right.originOrder);
    if (sourceOrder != 0) {
      return sourceOrder;
    }
    final int originOrder = left.origin.compareTo(right.origin);
    if (originOrder != 0) {
      return originOrder;
    }
    return left.bookUrl.compareTo(right.bookUrl);
  }

  /// 切换书源选择；空集合保留“全部”语义。
  void _toggleSource(String sourceUrl) {
    /// 从“全部”开始切换时先展开为显式全选集合。
    final Set<String> selected = _state.selectedSourceUrls.isEmpty
        ? _state.sources.map((source) => source.bookSourceUrl).toSet()
        : Set<String>.from(_state.selectedSourceUrls);
    if (!selected.add(sourceUrl)) {
      selected.remove(sourceUrl);
    }
    _emit(_state.copyWith(selectedSourceUrls: selected));
  }

  /// 只使用失败来源重新运行当前关键字。
  void _retryFailures() {
    /// 失败书源 URL。
    final Set<String> sourceUrls = _state.failures.map((BookSearchSourceFailure value) => value.sourceUrl).toSet();
    if (sourceUrls.isEmpty) {
      return;
    }
    _startSearch(_state.committedKeyword, sourceUrls: sourceUrls);
  }

  /// 停止当前搜索并使全部旧回调失效。
  void _cancel({required bool manual}) {
    /// 【搜书诊断日志】取消前是否存在运行句柄。
    final bool hadActiveRun = _run != null;
    _run?.cancel();
    _run = null;
    if (manual) {
      _generation += 1;
      _logger.info(
        tag: bookSearchUiLogTag,
        message: '用户取消搜索 hadActiveRun=$hadActiveRun newGeneration=$_generation',
      );
      _emit(
        _state.copyWith(
          searching: false,
          cancelled: true,
          pausedForBookInfo: false,
        ),
      );
    }
  }

  /// 用户清空搜索框时停止当前搜索并重置结果、失败和进度，回到初始态。
  void _clearSearch() {
    /// 【搜书诊断日志】记录清空前是否仍有运行中的搜索。
    final bool hadActiveRun = _run != null;
    _run?.cancel();
    _run = null;
    _generation += 1;
    _resultBooks.clear();
    _logger.info(
      tag: bookSearchUiLogTag,
      message: '搜索关键字被清空，重置结果列表 hadActiveRun=$hadActiveRun newGeneration=$_generation',
    );
    _emit(
      _state.copyWith(
        keyword: '',
        committedKeyword: '',
        searching: false,
        cancelled: false,
        pausedForBookInfo: false,
        results: const <BookSearchResultGroup>[],
        failures: const <BookSearchSourceFailure>[],
        progress: const BookSearchProgress(total: 0, completed: 0, succeeded: 0, failed: 0),
        clearPendingEnableAllSearchKeyword: true,
        clearError: true,
      ),
    );
  }

  /// 清空持久化历史。
  Future<void> _clearHistory() async {
    /// 清空开始时的历史作用域代次，防止账号切换后清空新账号页面列表。
    final int historyLoadGeneration = _historyLoadGeneration;
    await _historyGateway.clear();
    if (historyLoadGeneration != _historyLoadGeneration ||
        _stateController.isClosed) {
      return;
    }
    /// 【搜书诊断日志】只记录清空动作，不输出历史内容。
    _logger.info(tag: bookSearchUiLogTag, message: '搜索历史已清空');
    _emit(_state.copyWith(history: const <String>[]));
  }

  /// 发布新状态。
  void _emit(SearchUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 取消任务并释放流控制器。
  void dispose() {
    /// 【搜书诊断日志】记录页面销毁时是否仍有搜索任务。
    _logger.info(
      tag: bookSearchUiLogTag,
      message: '搜索页面释放 searching=${_state.searching} generation=$_generation',
    );
    _sourceLoadGeneration += 1;
    _historyLoadGeneration += 1;
    _generation += 1;
    _userScopeListenable.removeListener(_handleUserScopeChanged);
    _cancel(manual: false);
    unawaited(_bookSourceSubscription?.cancel());
    _bookSourceSubscription = null;
    unawaited(_adultContentRuleSubscription?.cancel());
    _adultContentRuleSubscription = null;
    _stateController.close();
    _effectController.close();
  }
}
