import 'dart:async';

import '../../domain/gateway/search_history_gateway.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../model/web_book/book_search_coordinator.dart';
import 'search_contract.dart';

/// 管理多书源搜索、旧任务隔离、历史和页面 Effect 的 MVI ViewModel。
final class SearchViewModel {
  /// 创建 ViewModel 并读取启用书源与历史。
  SearchViewModel({
    required BookSearchCoordinator coordinator,
    required SearchHistoryGateway historyGateway,
  }) : _coordinator = coordinator,
       _historyGateway = historyGateway {
    _initialize();
  }

  /// 多书源搜索协调器。
  final BookSearchCoordinator _coordinator;
  /// 搜索历史边界。
  final SearchHistoryGateway _historyGateway;
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
        _retryFailures();
      case ToggleSearchSourceIntent(sourceUrl: final String sourceUrl):
        _toggleSource(sourceUrl);
      case SelectAllSearchSourcesIntent():
        _emit(_state.copyWith(selectedSourceUrls: <String>{}));
      case ClearSearchHistoryIntent():
        _clearHistory();
      case OpenSearchResultIntent(group: final BookSearchResultGroup group, book: final SearchBook book):
        _effectController.add(OpenBookInfoEffect(group, book));
      case BackFromSearchIntent():
        _effectController.add(const CloseSearchEffect());
    }
  }

  /// 并行读取书源和历史，失败时保持页面可重试。
  Future<void> _initialize() async {
    try {
      /// 当前启用书源。
      final List<BookSource> sources = await _coordinator.loadEnabledSources();
      /// 已保存历史。
      final List<String> history = await _historyGateway.load();
      _emit(_state.copyWith(loadingSources: false, sources: sources, history: history));
    } catch (error) {
      _emit(_state.copyWith(loadingSources: false, errorMessage: '读取启用书源失败'));
    }
  }

  /// 开始新搜索并取消、隔离旧搜索。
  Future<void> _startSearch(String rawKeyword, {required Set<String> sourceUrls}) async {
    /// 去除首尾空白的关键字。
    final String keyword = rawKeyword.trim();
    if (keyword.isEmpty) {
      _effectController.add(const ShowSearchMessageEffect('请输入搜索关键字'));
      return;
    }
    _cancel(manual: false);
    _generation += 1;
    /// 本次搜索固定运行编号。
    final int generation = _generation;
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
      }
      /// 新运行句柄。
      final BookSearchRun run = await _coordinator.start(
        keyword: keyword,
        selectedSourceUrls: sourceUrls,
        onEvent: (BookSearchEvent event) => _handleEvent(generation, event),
      );
      if (generation != _generation) {
        run.cancel();
        return;
      }
      _run = run;
      await run.completion;
      if (generation == _generation && !run.isCancelled) {
        _emit(_state.copyWith(searching: false));
      }
    } catch (error) {
      if (generation == _generation) {
        _emit(_state.copyWith(searching: false, errorMessage: '搜索任务启动失败'));
      }
    }
  }

  /// 处理协调器事件，并用运行编号拒绝旧任务结果。
  void _handleEvent(int generation, BookSearchEvent event) {
    if (generation != _generation) {
      return;
    }
    switch (event) {
      case BookSearchResultsEvent(books: final List<SearchBook> books):
        _merge(books);
      case BookSearchFailureEvent(failure: final BookSearchSourceFailure failure):
        _emit(_state.copyWith(failures: <BookSearchSourceFailure>[..._state.failures, failure]));
      case BookSearchProgressEvent(progress: final BookSearchProgress progress):
        _emit(_state.copyWith(progress: progress));
    }
  }

  /// 按 Android 严格书名作者键合并来源，并按精确匹配和来源数排序。
  void _merge(List<SearchBook> books) {
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
    _run?.cancel();
    _run = null;
    if (manual) {
      _generation += 1;
      _emit(_state.copyWith(searching: false, cancelled: true));
    }
  }

  /// 清空持久化历史。
  Future<void> _clearHistory() async {
    await _historyGateway.clear();
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
    _generation += 1;
    _cancel(manual: false);
    _stateController.close();
    _effectController.close();
  }
}
