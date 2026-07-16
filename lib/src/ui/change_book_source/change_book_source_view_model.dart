import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../help/error/app_result.dart';
import '../../help/logging/app_logger.dart';
import '../../model/web_book/book_search_coordinator.dart';
import '../../model/web_book/change_source_coordinator.dart';
import 'change_book_source_contract.dart';

/// 管理整书换源搜索、候选预览、迁移选项和原子提交的 MVI ViewModel。
final class ChangeBookSourceViewModel {
  /// 创建页面生命周期独占的换源 ViewModel 并立即读取旧书籍事实。
  ChangeBookSourceViewModel({
    required this.bookUrl,
    required BookshelfGateway bookshelfGateway,
    required ChangeSourceCoordinator coordinator,
    required ChangeBookSourceUseCase changeBookSource,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
  }) : _bookshelfGateway = bookshelfGateway,
       _coordinator = coordinator,
       _changeBookSource = changeBookSource,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger {
    unawaited(_initialize());
  }

  /// 路由提供的旧书籍稳定 URL。
  final String bookUrl;

  /// 提供旧书读取和目标主键冲突检查能力的书架边界。
  final BookshelfGateway _bookshelfGateway;

  /// 复用 M6 网络、规则、详情和目录链路的换源协调器。
  final ChangeSourceCoordinator _coordinator;

  /// 负责用户事实迁移和数据库原子替换的业务动作。
  final ChangeBookSourceUseCase _changeBookSource;

  /// 为每次候选预览创建独立取消令牌的工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 统一换源日志接口，只记录不可逆标识、数量和状态。
  final AppLogger _logger;

  /// 当前可同步读取的完整页面状态。
  ChangeBookSourceUiState _state = ChangeBookSourceUiState();

  /// 状态广播控制器。
  final StreamController<ChangeBookSourceUiState> _stateController =
      StreamController<ChangeBookSourceUiState>.broadcast();

  /// 一次性 Effect 广播控制器。
  final StreamController<ChangeBookSourceEffect> _effectController =
      StreamController<ChangeBookSourceEffect>.broadcast();

  /// 当前多书源搜索运行句柄。
  BookSearchRun? _searchRun;

  /// 当前候选详情和目录请求令牌。
  HttpCancellationToken? _previewToken;

  /// 搜索世代，用于拒绝取消或重启后的旧回调。
  int _searchGeneration = 0;

  /// 候选预览世代，用于拒绝快速切换候选后的旧结果。
  int _previewGeneration = 0;

  /// 按“来源 URL + 书籍 URL”稳定键保存去重候选。
  final Map<(String, String), SearchBook> _candidateMap =
      <(String, String), SearchBook>{};

  /// 是否已经释放页面资源。
  bool _disposed = false;

  /// 当前可同步读取的页面状态。
  ChangeBookSourceUiState get state => _state;

  /// 后续不可变状态流。
  Stream<ChangeBookSourceUiState> get states => _stateController.stream;

  /// 页面一次性副作用流。
  Stream<ChangeBookSourceEffect> get effects => _effectController.stream;

  /// 整书换源页面所有用户操作的唯一入口。
  void onIntent(ChangeBookSourceIntent intent) {
    if (_state.applying) {
      if (intent is! ConfirmChangeBookSourceIntent) {
        _effectController.add(
          const ShowChangeBookSourceMessageEffect('正在提交整书换源，请等待完成'),
        );
      }
      return;
    }
    switch (intent) {
      case StartOrStopChangeSourceSearchIntent():
        if (_state.searching) {
          _cancelSearch(manual: true);
        } else {
          unawaited(_startSearch());
        }
      case ToggleChangeSourceAuthorCheckIntent(enabled: final bool enabled):
        if (enabled != _state.checkAuthor) {
          _emit(_state.copyWith(checkAuthor: enabled));
          unawaited(_startSearch());
        }
      case ToggleChangeSourceScopeIntent(sourceUrl: final String sourceUrl):
        _toggleScope(sourceUrl);
      case SelectAllChangeSourceScopesIntent():
        if (_state.selectedSourceUrls.isNotEmpty) {
          _emit(_state.copyWith(selectedSourceUrls: <String>{}));
          unawaited(_startSearch());
        }
      case SelectChangeSourceCandidateIntent(candidate: final SearchBook candidate):
        unawaited(_loadPreview(candidate));
      case DismissChangeSourcePreviewIntent():
        _cancelPreview();
        _emit(_state.copyWith(loadingPreview: false, clearSelection: true));
      case UpdateChangeSourceOptionsIntent(options: final ChangeSourceMigrationOptions options):
        _emit(_state.copyWith(options: options));
      case ConfirmChangeBookSourceIntent():
        unawaited(_applyChange());
      case BackFromChangeBookSourceIntent():
        if (_state.selectedCandidate != null) {
          _cancelPreview();
          _emit(_state.copyWith(loadingPreview: false, clearSelection: true));
        } else {
          _cancelSearch(manual: false);
          _effectController.add(const CloseChangeBookSourceEffect());
        }
    }
  }

  /// 读取旧书和启用书源；成功后自动执行第一次全范围搜索。
  Future<void> _initialize() async {
    if (bookUrl.isEmpty) {
      _emit(
        _state.copyWith(
          initializing: false,
          errorMessage: '换源入口缺少书籍 URL',
        ),
      );
      return;
    }
    try {
      /// 当前书架中的旧书籍事实。
      final Book? oldBook = await _bookshelfGateway.getBook(bookUrl);
      if (oldBook == null) {
        _emit(
          _state.copyWith(
            initializing: false,
            errorMessage: '目标书籍已不在书架中',
          ),
        );
        return;
      }
      if (oldBook.origin == 'loc_book') {
        _emit(
          _state.copyWith(
            initializing: false,
            oldBook: oldBook,
            errorMessage: '本地书不支持整书换源',
          ),
        );
        return;
      }
      /// 当前启用书源快照。
      final List<BookSource> sources = await _coordinator.loadEnabledSources();
      _emit(
        _state.copyWith(
          initializing: false,
          oldBook: oldBook,
          sources: sources,
          clearError: true,
        ),
      );
      if (sources.isEmpty) {
        _emit(_state.copyWith(errorMessage: '当前没有启用书源'));
        return;
      }
      await _startSearch();
    } on Object catch (error, stackTrace) {
      _logger.error(
        tag: bookSourceChangeLogTag,
        message: '换源页面初始化失败 oldBookId=${appLogDiagnosticId(bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(
        _state.copyWith(
          initializing: false,
          errorMessage: '读取书籍或启用书源失败',
        ),
      );
    }
  }

  /// 取消旧任务、清空候选并开始新的有界多书源搜索。
  Future<void> _startSearch() async {
    /// 当前旧书籍事实。
    final Book? oldBook = _state.oldBook;
    if (oldBook == null || _state.initializing || _state.sources.isEmpty) {
      return;
    }
    _cancelSearch(manual: false);
    _cancelPreview();
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
        progress: BookSearchProgress(
          total: totalSources,
          completed: 0,
          succeeded: 0,
          failed: 0,
        ),
        candidates: const <SearchBook>[],
        failures: const <BookSearchSourceFailure>[],
        loadingPreview: false,
        clearSelection: true,
        clearError: true,
      ),
    );
    try {
      /// 当前搜索运行句柄。
      final BookSearchRun run = await _coordinator.startSearch(
        oldBook: oldBook,
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
          message: '换源候选搜索失败 generation=$generation '
              'oldBookId=${appLogDiagnosticId(oldBook.bookUrl)}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(
          _state.copyWith(
            searching: false,
            errorMessage: '换源搜索启动失败',
          ),
        );
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
        _emit(
          _state.copyWith(
            failures: <BookSearchSourceFailure>[..._state.failures, failure],
          ),
        );
      case BookSearchProgressEvent(progress: final BookSearchProgress progress):
        _emit(_state.copyWith(progress: progress));
    }
  }

  /// 按搜索页语义切换明确书源范围；空集合始终表示全部启用书源。
  void _toggleScope(String sourceUrl) {
    /// 从“全部”状态开始时先展开全部 URL，再切换目标来源。
    final Set<String> selected = _state.selectedSourceUrls.isEmpty
        ? _state.sources.map((BookSource source) => source.bookSourceUrl).toSet()
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

  /// 停止候选详情请求并使旧结果失效。
  void _cancelPreview() {
    _previewGeneration += 1;
    _previewToken?.cancel('换源候选预览已替换');
    _previewToken = null;
  }

  /// 加载用户选择候选的详情和完整目录，并检查书架主键冲突。
  Future<void> _loadPreview(SearchBook candidate) async {
    _cancelSearch(manual: false);
    _cancelPreview();
    _previewGeneration += 1;
    /// 本次候选预览世代。
    final int generation = _previewGeneration;
    /// 本次候选请求取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _previewToken = token;
    _emit(
      _state.copyWith(
        searching: false,
        loadingPreview: false,
        clearSelection: true,
      ),
    );
    _emit(
      _state.copyWith(
        selectedCandidate: candidate,
        loadingPreview: true,
        previewChapters: const [],
        clearPreviewError: true,
      ),
    );
    try {
      /// 完成详情和目录解析的候选预览。
      final ChangeSourceCandidatePreview preview = await _coordinator.loadCandidate(
        candidate: candidate,
        cancellationToken: token,
      );
      if (_disposed || generation != _previewGeneration) {
        return;
      }
      /// 与候选主键相同的现有书架记录。
      final Book? conflict = await _bookshelfGateway.getBook(preview.book.bookUrl);
      /// 当前正在被替换的旧书。
      final Book? oldBook = _state.oldBook;
      if (conflict != null && conflict.bookUrl != oldBook?.bookUrl) {
        _emit(
          _state.copyWith(
            loadingPreview: false,
            previewError: '目标来源的书籍已经在书架中',
          ),
        );
        return;
      }
      _emit(
        _state.copyWith(
          loadingPreview: false,
          previewBook: preview.book,
          previewChapters: preview.chapters,
          clearPreviewError: true,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (!_disposed && generation == _previewGeneration) {
        _logger.error(
          tag: bookSourceChangeLogTag,
          message: '换源候选预览失败 sourceId=${appLogDiagnosticId(candidate.origin)} '
              'bookId=${appLogDiagnosticId(candidate.bookUrl)}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(
          _state.copyWith(
            loadingPreview: false,
            previewError: '候选详情或目录加载失败',
          ),
        );
      }
    }
  }

  /// 把当前完整候选和迁移选项提交给领域 UseCase。
  Future<void> _applyChange() async {
    if (_state.applying) {
      return;
    }
    /// 当前旧书籍事实。
    final Book? oldBook = _state.oldBook;
    /// 已完成详情和目录解析的新书籍事实。
    final Book? newBook = _state.previewBook;
    if (oldBook == null || newBook == null || _state.previewChapters.isEmpty) {
      _effectController.add(
        const ShowChangeBookSourceMessageEffect('请先选择并完成候选目录加载'),
      );
      return;
    }
    _emit(_state.copyWith(applying: true));
    /// 整书换源领域结果。
    final AppResult<ChangeBookSourceResult> result = await _changeBookSource.execute(
      oldBook: oldBook,
      newBook: newBook,
      chapters: _state.previewChapters,
      options: _state.options,
    );
    if (_disposed) {
      return;
    }
    switch (result) {
      case AppSuccess<ChangeBookSourceResult>(value: final ChangeBookSourceResult value):
        _emit(_state.copyWith(applying: false));
        _effectController.add(CompleteChangeBookSourceEffect(value));
      case AppFailure<ChangeBookSourceResult>(error: final error):
        _emit(_state.copyWith(applying: false));
        _effectController.add(ShowChangeBookSourceMessageEffect(error.message));
    }
  }

  /// 发布新状态；释放后不再写入关闭的流。
  void _emit(ChangeBookSourceUiState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    _stateController.add(state);
  }

  /// 取消搜索、预览和流订阅资源。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelSearch(manual: false);
    _cancelPreview();
    _stateController.close();
    _effectController.close();
  }
}
