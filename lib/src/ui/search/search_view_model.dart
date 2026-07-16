import 'dart:async';

import '../../domain/gateway/search_history_gateway.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import '../../model/web_book/book_search_coordinator.dart';
import 'search_contract.dart';

/// 管理多书源搜索、旧任务隔离、历史和页面 Effect 的 MVI ViewModel。
final class SearchViewModel {
  /// 创建 ViewModel 并读取启用书源与历史。
  SearchViewModel({
    required BookSearchCoordinator coordinator,
    required SearchHistoryGateway historyGateway,
    required AppLogger logger,
  }) : _coordinator = coordinator,
       _historyGateway = historyGateway,
       _logger = logger {
    _initialize();
  }

  /// 多书源搜索协调器。
  final BookSearchCoordinator _coordinator;
  /// 搜索历史边界。
  final SearchHistoryGateway _historyGateway;
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
  /// 每次搜索递增的运行编号，用于拒绝旧回调污染新状态。
  int _generation = 0;
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
        _emit(_state.copyWith(keyword: keyword, clearError: true));
      case SubmitSearchIntent(keyword: final String? keyword):
        _startSearch(keyword ?? _state.keyword, sourceUrls: _state.selectedSourceUrls);
      case CancelSearchIntent():
        _cancel(manual: true);
      case RetryFailedSourcesIntent():
        /// 【搜书诊断日志】记录用户从失败书源区域触发重试。
        _logger.info(
          tag: bookSearchUiLogTag,
          message: '用户重试失败书源 failureCount=${_state.failures.length}',
        );
        _retryFailures();
      case ToggleSearchSourceIntent(sourceUrl: final String sourceUrl):
        _toggleSource(sourceUrl);
      case SelectAllSearchSourcesIntent():
        _emit(_state.copyWith(selectedSourceUrls: <String>{}));
      case ClearSearchHistoryIntent():
        _clearHistory();
      case OpenSearchResultIntent(group: final BookSearchResultGroup group, book: final SearchBook book):
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

  /// 并行读取书源和历史，失败时保持页面可重试。
  Future<void> _initialize() async {
    /// 【搜书诊断日志】初始化耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(tag: bookSearchUiLogTag, message: '搜索页面初始化开始');
    try {
      /// 当前启用书源。
      final List<BookSource> sources = await _coordinator.loadEnabledSources();
      /// 已保存历史。
      final List<String> history = await _historyGateway.load();
      _emit(_state.copyWith(loadingSources: false, sources: sources, history: history));
      _logger.info(
        tag: bookSearchUiLogTag,
        message: '搜索页面初始化完成 sourceCount=${sources.length} '
            'historyCount=${history.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error, stackTrace) {
      _logger.error(
        tag: bookSearchUiLogTag,
        message: '搜索页面初始化失败 elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(_state.copyWith(loadingSources: false, errorMessage: '读取启用书源失败'));
    }
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
        results: const <BookSearchResultGroup>[],
        failures: const <BookSearchSourceFailure>[],
        progress: BookSearchProgress(total: sourceUrls.isEmpty ? _state.sources.length : sourceUrls.length, completed: 0, succeeded: 0, failed: 0),
        clearError: true,
      ),
    );
    try {
      /// 写入并返回的新历史。
      final List<String> history = await _historyGateway.record(keyword);
      if (generation == _generation) {
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
      if (generation == _generation && !run.isCancelled) {
        _emit(_state.copyWith(searching: false));
        _logger.info(
          tag: bookSearchUiLogTag,
          message: '搜索任务完成 generation=$generation groupCount=${_state.results.length} '
              'failureCount=${_state.failures.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
      }
    } catch (error, stackTrace) {
      if (generation == _generation) {
        _logger.error(
          tag: bookSearchUiLogTag,
          message: '搜索任务启动或等待失败 generation=$generation '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(searching: false, errorMessage: '搜索任务启动失败'));
      }
    }
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
      /// 避免拼接碰撞的内部键。
      final String key = '${book.name.length}:${book.name}${book.author}';
      /// 当前同名作者来源列表。
      final List<SearchBook> candidates = _resultBooks.putIfAbsent(key, () => <SearchBook>[]);
      if (!candidates.any((SearchBook value) => value.origin == book.origin && value.bookUrl == book.bookUrl)) {
        candidates.add(book);
      }
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
      _emit(_state.copyWith(searching: false, cancelled: true));
    }
  }

  /// 清空持久化历史。
  Future<void> _clearHistory() async {
    await _historyGateway.clear();
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
    _generation += 1;
    _cancel(manual: false);
    _stateController.close();
    _effectController.close();
  }
}
