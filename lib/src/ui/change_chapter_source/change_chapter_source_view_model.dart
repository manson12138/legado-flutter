import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import '../../model/web_book/book_search_coordinator.dart';
import '../../model/web_book/change_chapter_source_coordinator.dart';
import 'change_chapter_source_contract.dart';

/// 管理单章换源候选搜索、目录预览和正文拉取的 MVI ViewModel。
///
/// 与整书换源不同，本 ViewModel 不持有书架读取边界——调用方已经在阅读器里持有当前
/// 书籍和目标章节事实，直接通过构造参数传入即可，构造完成后立即开始搜索。
final class ChangeChapterSourceViewModel {
  /// 创建面板生命周期独占的单章换源 ViewModel 并立即开始搜索。
  ChangeChapterSourceViewModel({
    required Book book,
    required int chapterIndex,
    required String chapterTitle,
    required this.totalChapterCount,
    required ChangeChapterSourceCoordinator coordinator,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
  }) : _coordinator = coordinator,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger,
       _state = ChangeChapterSourceUiState(
         book: book,
         chapterIndex: chapterIndex,
         chapterTitle: chapterTitle,
       ) {
    unawaited(_initialize());
  }

  /// 打开面板时目标书籍的完整目录长度，用于换算候选目录中的预选位置。
  final int totalChapterCount;

  /// 复用整书换源基础设施并新增章节级目录匹配的协调器。
  final ChangeChapterSourceCoordinator _coordinator;

  /// 为每次候选目录/正文请求创建独立取消令牌的工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 统一换源日志接口，只记录不可逆标识、数量和状态。
  final AppLogger _logger;

  /// 当前可同步读取的完整面板状态。
  ChangeChapterSourceUiState _state;

  /// 状态广播控制器。
  final StreamController<ChangeChapterSourceUiState> _stateController =
      StreamController<ChangeChapterSourceUiState>.broadcast();

  /// 一次性 Effect 广播控制器。
  final StreamController<ChangeChapterSourceEffect> _effectController =
      StreamController<ChangeChapterSourceEffect>.broadcast();

  /// 当前多书源搜索运行句柄。
  BookSearchRun? _searchRun;

  /// 当前候选目录/正文请求令牌。
  HttpCancellationToken? _tocToken;

  /// 搜索世代，用于拒绝取消或重启后的旧回调。
  int _searchGeneration = 0;

  /// 目录/正文请求世代，用于拒绝快速切换候选后的旧结果。
  int _tocGeneration = 0;

  /// 按“来源 URL + 书籍 URL”稳定键保存去重候选。
  final Map<(String, String), SearchBook> _candidateMap = <(String, String), SearchBook>{};

  /// 是否已经释放面板资源。
  bool _disposed = false;

  /// 当前可同步读取的面板状态。
  ChangeChapterSourceUiState get state => _state;

  /// 后续不可变状态流。
  Stream<ChangeChapterSourceUiState> get states => _stateController.stream;

  /// 面板一次性副作用流。
  Stream<ChangeChapterSourceEffect> get effects => _effectController.stream;

  /// 单章换源面板所有用户操作的唯一入口。
  void onIntent(ChangeChapterSourceIntent intent) {
    if (_state.fetchingContent) {
      return;
    }
    switch (intent) {
      case StartOrStopChangeChapterSourceSearchIntent():
        if (_state.searching) {
          _cancelSearch(manual: true);
        } else {
          unawaited(_startSearch());
        }
      case ToggleChangeChapterSourceAuthorCheckIntent(enabled: final bool enabled):
        if (enabled != _state.checkAuthor) {
          _emit(_state.copyWith(checkAuthor: enabled));
          unawaited(_startSearch());
        }
      case ToggleChangeChapterSourceScopeIntent(sourceUrl: final String sourceUrl):
        _toggleScope(sourceUrl);
      case SelectAllChangeChapterSourceScopesIntent():
        if (_state.selectedSourceUrls.isNotEmpty) {
          _emit(_state.copyWith(selectedSourceUrls: <String>{}));
          unawaited(_startSearch());
        }
      case SelectChangeChapterSourceCandidateIntent(candidate: final SearchBook candidate):
        unawaited(_loadToc(candidate));
      case SelectChangeChapterSourceTocChapterIntent(chapter: final BookChapter chapter):
        unawaited(_fetchChapterContent(chapter));
      case BackFromChangeChapterSourceTocIntent():
        _cancelToc();
        _emit(_state.copyWith(clearToc: true));
      case DismissChangeChapterSourceIntent():
        _cancelSearch(manual: false);
        _cancelToc();
        _effectController.add(const DismissChangeChapterSourceEffect());
    }
  }

  /// 读取启用书源后开始第一次全范围搜索。
  Future<void> _initialize() async {
    try {
      /// 当前启用书源快照。
      final sources = await _coordinator.loadEnabledSources();
      _emit(_state.copyWith(sources: sources, clearError: true));
      if (sources.isEmpty) {
        _emit(_state.copyWith(errorMessage: '当前没有启用书源'));
        return;
      }
      await _startSearch();
    } on Object catch (error, stackTrace) {
      _logger.error(
        tag: bookSourceChangeLogTag,
        message: '单章换源面板初始化失败 bookId=${appLogDiagnosticId(_state.book.bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(_state.copyWith(errorMessage: '读取启用书源失败'));
    }
  }

  /// 取消旧任务、清空候选并开始新的有界多书源搜索。
  Future<void> _startSearch() async {
    if (_state.sources.isEmpty) {
      return;
    }
    _cancelSearch(manual: false);
    _cancelToc();
    _searchGeneration += 1;
    /// 本次搜索世代。
    final int generation = _searchGeneration;
    _candidateMap.clear();
    /// 本次实际书源总数；空选择表示全部启用书源。
    final int totalSources = _state.selectedSourceUrls.isEmpty
        ? _state.sources.length
        : _state.selectedSourceUrls.length;
    _emit(
      _state.copyWith(
        searching: true,
        cancelled: false,
        progress: BookSearchProgress(total: totalSources, completed: 0, succeeded: 0, failed: 0),
        candidates: const <SearchBook>[],
        failures: const <BookSearchSourceFailure>[],
        clearToc: true,
        clearError: true,
      ),
    );
    try {
      /// 当前搜索运行句柄。
      final BookSearchRun run = await _coordinator.startSearch(
        book: _state.book,
        checkAuthor: _state.checkAuthor,
        selectedSourceUrls: _state.selectedSourceUrls,
        onEvent: (BookSearchEvent event) => _handleSearchEvent(generation, event),
      );
      if (_disposed || generation != _searchGeneration) {
        run.cancel();
        return;
      }
      _searchRun = run;
      await run.completion;
      if (!_disposed && generation == _searchGeneration && !run.isCancelled) {
        _emit(_state.copyWith(searching: false));
      }
    } on Object catch (error, stackTrace) {
      if (!_disposed && generation == _searchGeneration) {
        _logger.error(
          tag: bookSourceChangeLogTag,
          message: '单章换源候选搜索失败 generation=$generation '
              'bookId=${appLogDiagnosticId(_state.book.bookUrl)}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(searching: false, errorMessage: '换源搜索启动失败'));
      }
    }
  }

  /// 合并当前世代的候选、失败和进度事件。
  void _handleSearchEvent(int generation, BookSearchEvent event) {
    if (_disposed || generation != _searchGeneration) {
      return;
    }
    switch (event) {
      case BookSearchResultsEvent(books: final List<SearchBook> books):
        for (final SearchBook book in books) {
          /// 候选去重键，与页面稳定 key 使用相同业务事实。
          final (String, String) key = (book.origin, book.bookUrl);
          _candidateMap[key] = book;
        }
        /// 按书源排序值、来源名称和详情 URL 生成稳定展示顺序。
        final List<SearchBook> candidates = _candidateMap.values.toList(growable: false)
          ..sort((SearchBook left, SearchBook right) {
            /// 书源排序值比较结果。
            final int originOrder = left.originOrder.compareTo(right.originOrder);
            if (originOrder != 0) {
              return originOrder;
            }
            /// 来源显示名称比较结果。
            final int sourceName = left.originName.compareTo(right.originName);
            return sourceName != 0 ? sourceName : left.bookUrl.compareTo(right.bookUrl);
          });
        _emit(_state.copyWith(candidates: candidates));
      case BookSearchFailureEvent(failure: final BookSearchSourceFailure failure):
        _emit(_state.copyWith(failures: <BookSearchSourceFailure>[..._state.failures, failure]));
      case BookSearchProgressEvent(progress: final BookSearchProgress progress):
        _emit(_state.copyWith(progress: progress));
    }
  }

  /// 按搜索页语义切换明确书源范围；空集合始终表示全部启用书源。
  void _toggleScope(String sourceUrl) {
    /// 从“全部”状态开始时先展开全部 URL，再切换目标来源。
    final Set<String> selected = _state.selectedSourceUrls.isEmpty
        ? _state.sources.map((source) => source.bookSourceUrl).toSet()
        : Set<String>.from(_state.selectedSourceUrls);
    if (!selected.add(sourceUrl)) {
      selected.remove(sourceUrl);
    }
    _emit(_state.copyWith(selectedSourceUrls: selected));
    unawaited(_startSearch());
  }

  /// 停止搜索并按需要记录用户主动取消状态。
  void _cancelSearch({required bool manual}) {
    _searchGeneration += 1;
    _searchRun?.cancel();
    _searchRun = null;
    if (manual) {
      _emit(_state.copyWith(searching: false, cancelled: true));
    }
  }

  /// 停止目录/正文请求并使旧结果失效。
  void _cancelToc() {
    _tocGeneration += 1;
    _tocToken?.cancel('单章换源候选已切换');
    _tocToken = null;
  }

  /// 加载用户选择候选的完整目录并模糊预选章节位置。
  Future<void> _loadToc(SearchBook candidate) async {
    _cancelSearch(manual: false);
    _cancelToc();
    _tocGeneration += 1;
    /// 本次目录加载世代。
    final int generation = _tocGeneration;
    /// 本次目录请求取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _tocToken = token;
    _emit(
      _state.copyWith(
        searching: false,
        selectedCandidate: candidate,
        showToc: true,
        loadingToc: true,
        clearTocError: true,
      ),
    );
    try {
      /// 完成目录解析和预选的候选目录。
      final ChangeChapterSourceCandidateToc toc = await _coordinator.loadCandidateToc(
        candidate: candidate,
        oldChapterIndex: _state.chapterIndex,
        oldChapterTitle: _state.chapterTitle,
        oldChapterListSize: totalChapterCount,
        cancellationToken: token,
      );
      if (_disposed || generation != _tocGeneration) {
        return;
      }
      _emit(
        _state.copyWith(
          loadingToc: false,
          tocChapters: toc.chapters,
          tocSource: toc.source,
          preselectedTocIndex: toc.preselectedIndex,
          clearTocError: true,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (!_disposed && generation == _tocGeneration) {
        _logger.error(
          tag: bookSourceChangeLogTag,
          message: '单章换源候选目录加载失败 sourceId=${appLogDiagnosticId(candidate.origin)} '
              'bookId=${appLogDiagnosticId(candidate.bookUrl)}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(loadingToc: false, tocError: '候选目录加载失败'));
      }
    }
  }

  /// 拉取用户选定章节的正文并请求外层阅读器替换。
  Future<void> _fetchChapterContent(BookChapter chapter) async {
    /// 当前候选目录对应书源。
    final source = _state.tocSource;
    if (!_state.canSelectChapter || source == null) {
      return;
    }
    _cancelToc();
    _tocGeneration += 1;
    /// 本次正文拉取世代。
    final int generation = _tocGeneration;
    /// 本次正文拉取取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _tocToken = token;
    _emit(_state.copyWith(fetchingContent: true));
    try {
      /// 候选来源已拉取到的章节正文。
      final String content = await _coordinator.fetchChapterContent(
        source: source,
        chapter: chapter,
        cancellationToken: token,
      );
      if (_disposed || generation != _tocGeneration) {
        return;
      }
      _emit(_state.copyWith(fetchingContent: false));
      _effectController.add(
        ReplaceChangeChapterSourceContentEffect(_state.chapterIndex, content),
      );
    } on Object catch (error, stackTrace) {
      if (!_disposed && generation == _tocGeneration) {
        _logger.error(
          tag: bookSourceChangeLogTag,
          message: '单章换源正文拉取失败 sourceId=${appLogDiagnosticId(source.bookSourceUrl)} '
              'chapterId=${appLogDiagnosticId(chapter.url)}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(fetchingContent: false));
        _effectController.add(const ShowChangeChapterSourceMessageEffect('候选章节正文拉取失败'));
      }
    }
  }

  /// 发布新状态；释放后不再写入关闭的流。
  void _emit(ChangeChapterSourceUiState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    _stateController.add(state);
  }

  /// 取消搜索、目录请求和流订阅资源。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelSearch(manual: false);
    _cancelToc();
    _stateController.close();
    _effectController.close();
  }
}
