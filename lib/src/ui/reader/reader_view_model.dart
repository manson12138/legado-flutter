import 'dart:async';
import 'dart:math' as math;

import '../../domain/gateway/bookmark_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/gateway/replace_rule_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/reading_progress.dart';
import '../../domain/model/replace_rule.dart';
import '../../domain/usecase/load_book_chapters_use_case.dart';
import '../../domain/usecase/restore_reading_progress_use_case.dart';
import '../../domain/usecase/save_reading_progress_use_case.dart';
import '../../help/error/app_result.dart';
import '../../help/logging/app_logger.dart';
import '../../model/reader/read_book_coordinator.dart';
import 'reader_contract.dart';

/// 管理正文加载、稳定进度、章节切换、书签、设置和预加载的阅读器 MVI ViewModel。
final class ReaderViewModel {
  /// 创建页面生命周期独占的阅读器 ViewModel。
  ReaderViewModel({
    required this.bookUrl,
    this.initialChapterIndex,
    required BookshelfGateway bookshelfGateway,
    required LoadBookChaptersUseCase loadBookChapters,
    required RestoreReadingProgressUseCase restoreReadingProgress,
    required SaveReadingProgressUseCase saveReadingProgress,
    required BookmarkGateway bookmarkGateway,
    required ReplaceRuleGateway replaceRuleGateway,
    required ReaderCacheGateway cacheGateway,
    required ReadBookCoordinator coordinator,
    required AppLogger logger,
  }) : _bookshelfGateway = bookshelfGateway,
       _loadBookChapters = loadBookChapters,
       _restoreReadingProgress = restoreReadingProgress,
       _saveReadingProgress = saveReadingProgress,
       _bookmarkGateway = bookmarkGateway,
       _replaceRuleGateway = replaceRuleGateway,
       _cacheGateway = cacheGateway,
       _coordinator = coordinator,
       _logger = logger;

  /// 路由提供的稳定书籍 URL。
  final String bookUrl;

  /// 详情目录入口指定的初始章节索引；为空时恢复稳定锚点或旧进度。
  final int? initialChapterIndex;

  /// 书架书读取边界。
  final BookshelfGateway _bookshelfGateway;

  /// 持久目录读取 UseCase。
  final LoadBookChaptersUseCase _loadBookChapters;

  /// 旧兼容进度恢复 UseCase。
  final RestoreReadingProgressUseCase _restoreReadingProgress;

  /// 章节索引和字符位置保存 UseCase。
  final SaveReadingProgressUseCase _saveReadingProgress;

  /// 书签持久化边界。
  final BookmarkGateway _bookmarkGateway;

  /// 替换规则读取边界，用于展示当前书的完整可用规则列表。
  final ReplaceRuleGateway _replaceRuleGateway;

  /// 稳定锚点、正文和显示配置缓存边界。
  final ReaderCacheGateway _cacheGateway;

  /// 对应 Android ReadBook 的正文加载协调器。
  final ReadBookCoordinator _coordinator;

  /// 【搜书诊断日志】项目统一日志接口，用于记录阅读入口和章节状态。
  final AppLogger _logger;

  /// 当前完整页面状态。
  ReaderUiState _state = ReaderUiState();

  /// 状态广播控制器。
  final StreamController<ReaderUiState> _stateController = StreamController<ReaderUiState>.broadcast();

  /// 一次性 Effect 广播控制器。
  final StreamController<ReaderEffect> _effectController = StreamController<ReaderEffect>.broadcast();

  /// 当前书签流订阅。
  StreamSubscription<List<Bookmark>>? _bookmarkSubscription;

  /// 滚动锚点状态更新节流定时器。
  Timer? _anchorUpdateTimer;

  /// 阅读进度持久化节流定时器。
  Timer? _progressSaveTimer;

  /// 最近一次滚动换算得到的字符位置。
  int _pendingCharacterOffset = 0;

  /// 章节加载世代，阻止旧 Future 覆盖快速切换后的新章节。
  int _loadGeneration = 0;

  /// 是否已释放页面资源。
  bool _disposed = false;

  /// 是否正在切换相邻章节，防止滚动边界重复通知创建并发切章。
  bool _changingRelativeChapter = false;

  /// 后台刷新章节世代，释放或再次刷新时让旧任务自然停止。
  int _refreshGeneration = 0;

  /// 整书搜索世代，避免旧搜索结果覆盖用户最新关键词。
  int _searchGeneration = 0;

  /// 当前可同步读取的状态。
  ReaderUiState get state => _state;

  /// 后续状态流。
  Stream<ReaderUiState> get states => _stateController.stream;

  /// 一次性 Effect 流。
  Stream<ReaderEffect> get effects => _effectController.stream;

  /// 阅读器所有用户和生命周期操作的唯一入口。
  void onIntent(ReaderIntent intent) {
    switch (intent) {
      case InitializeReaderIntent():
        unawaited(_initialize());
      case UpdateReaderScrollIntent(characterOffset: final int characterOffset):
        _updateScroll(characterOffset);
      case OpenPreviousChapterIntent():
        unawaited(_openRelativeChapter(-1));
      case OpenNextChapterIntent():
        unawaited(_openRelativeChapter(1));
      case OpenReaderChapterIntent(
        chapterIndex: final int chapterIndex,
        characterOffset: final int characterOffset,
      ):
        unawaited(_openChapter(chapterIndex, characterOffset: characterOffset));
      case RetryReaderChapterIntent(forceRefresh: final bool forceRefresh):
        unawaited(_loadCurrentChapter(forceRefresh: forceRefresh));
      case RefreshReaderChaptersIntent(scope: final ReaderRefreshScope scope):
        unawaited(_refreshChapters(scope));
      case ToggleReaderMenuIntent():
        _emit(_state.copyWith(menuVisible: !_state.menuVisible));
      case ShowReaderSheetIntent(sheet: final ReaderSheet sheet):
        _emit(_state.copyWith(activeSheet: sheet));
        if (sheet is ReaderReplaceInfoSheet) {
          unawaited(_loadReplaceRules());
        }
      case DismissReaderSheetIntent():
        _emit(_state.copyWith(clearSheet: true));
      case UpdateReaderConfigIntent(config: final ReaderDisplayConfig config):
        unawaited(_updateConfig(config));
      case UpdateReaderSystemInfoIntent(batteryLevel: final int? batteryLevel):
        _emit(_state.copyWith(batteryLevel: batteryLevel, clearBattery: batteryLevel == null));
      case AddReaderBookmarkIntent():
        unawaited(_addBookmark());
      case DeleteReaderBookmarkIntent(bookmark: final Bookmark bookmark):
        unawaited(_deleteBookmark(bookmark));
      case SaveReaderBookmarkNoteIntent(
        bookmark: final Bookmark bookmark,
        content: final String content,
      ):
        unawaited(_saveBookmarkNote(bookmark, content));
      case OpenReaderBookmarkIntent(bookmark: final Bookmark bookmark):
        _emit(_state.copyWith(clearSheet: true));
        unawaited(
          _openChapter(bookmark.chapterIndex, characterOffset: bookmark.chapterPos),
        );
      case UpdateReaderSearchQueryIntent(query: final String query):
        _updateSearchQuery(query);
      case UpdateReaderSearchScopeIntent(scope: final ReaderSearchScope scope):
        _updateSearchScope(scope);
      case SubmitReaderSearchIntent():
        unawaited(_submitSearch());
      case OpenReaderSearchResultIntent(index: final int index):
        unawaited(_openSearchResult(index));
      case NavigateReaderSearchResultIntent(direction: final int direction):
        unawaited(_navigateSearchResult(direction));
      case ExportReaderBookmarksIntent():
        _exportBookmarks();
      case PauseReaderIntent():
        unawaited(_saveProgress());
      case ReaderMemoryPressureIntent():
        _coordinator.handleMemoryPressure();
      case OpenReaderBookSourceChangeIntent():
        unawaited(_requestBookSourceChange());
      case SaveReaderChapterSourceContentIntent(
        chapterIndex: final int chapterIndex,
        content: final String content,
      ):
        unawaited(_saveChapterSourceContent(chapterIndex, content));
      case CloseReaderIntent():
        unawaited(_close());
    }
  }

  /// 初始化书籍、目录、配置、稳定锚点和兼容进度。
  Future<void> _initialize() async {
    /// 【搜书诊断日志】阅读器初始化不可逆书籍标识。
    final String bookId = appLogDiagnosticId(bookUrl);
    /// 【搜书诊断日志】阅读器初始化耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(tag: bookReaderEntryLogTag, message: '阅读器初始化开始 bookId=$bookId');
    if (bookUrl.isEmpty) {
      _logger.error(tag: bookReaderEntryLogTag, message: '阅读器初始化失败 reason=emptyBookUrl');
      _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '阅读入口缺少书籍 URL'));
      return;
    }
    try {
      /// 当前书架书。
      final Book? book = await _bookshelfGateway.getBook(bookUrl);
      if (book == null) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '阅读器初始化终止 bookId=$bookId reason=bookNotInBookshelf',
        );
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '书籍已不在书架中'));
        return;
      }
      /// 持久目录读取结果。
      final AppResult<List<BookChapter>> chaptersResult = await _loadBookChapters.execute(bookUrl);
      if (chaptersResult is AppFailure<List<BookChapter>>) {
        _logger.error(
          tag: bookReaderEntryLogTag,
          message: '阅读器目录读取失败 bookId=$bookId',
          error: chaptersResult.error,
        );
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: chaptersResult.error.message));
        return;
      }
      /// 已确认成功的目录。
      final List<BookChapter> chapters = (chaptersResult as AppSuccess<List<BookChapter>>).value;
      if (chapters.isEmpty) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '阅读器初始化终止 bookId=$bookId reason=emptyToc',
        );
        _emit(_state.copyWith(book: book, loadState: ReaderLoadState.error, errorMessage: '书籍目录为空，请先在详情页刷新目录'));
        return;
      }
      /// 目录中是否至少存在一个可阅读章节。
      final bool hasReadableChapter = chapters.any(
        (BookChapter chapter) => !chapter.isVolume,
      );
      if (!hasReadableChapter) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '阅读器初始化终止 bookId=$bookId reason=noReadableChapter '
              'chapterCount=${chapters.length}',
        );
        _emit(_state.copyWith(book: book, loadState: ReaderLoadState.error, errorMessage: '目录中没有可阅读章节'));
        return;
      }
      /// 单书显示配置。
      final ReaderDisplayConfig config = await _cacheGateway.getDisplayConfig(bookUrl);
      /// 稳定章节地址和字符锚点。
      final ReaderPositionAnchor? stableAnchor = await _cacheGateway.getPositionAnchor(bookUrl);
      /// 兼容 M02 书籍字段的旧阅读进度。
      final AppResult<ReadingProgress?> progressResult = await _restoreReadingProgress.execute(bookUrl);
      /// 可用旧进度。
      final ReadingProgress? progress = progressResult is AppSuccess<ReadingProgress?>
          ? progressResult.value
          : null;
      /// 优先使用路由指定章节，其次通过章节 URL 恢复，最后回退旧索引。
      final int chapterIndex = _resolveInitialChapter(
        chapters,
        stableAnchor,
        progress,
        initialChapterIndex,
      );
      /// 初始字符位置。
      final int characterOffset = initialChapterIndex == null
          ? stableAnchor?.characterOffset ?? progress?.chapterPos ?? 0
          : 0;
      /// 【搜书诊断日志】记录恢复策略和位置，不记录附近正文摘要。
      _logger.info(
        tag: bookReaderEntryLogTag,
        message: '阅读位置解析完成 bookId=$bookId chapterCount=${chapters.length} '
            'chapterIndex=$chapterIndex characterOffset=$characterOffset '
            'usedRouteInitialChapter=${initialChapterIndex != null} '
            'usedStableAnchor=${initialChapterIndex == null && stableAnchor != null} '
            'usedLegacyProgress=${initialChapterIndex == null && stableAnchor == null && progress != null}',
      );
      _pendingCharacterOffset = math.max(0, characterOffset);
      _emit(
        _state.copyWith(
          book: book,
          chapters: chapters,
          currentChapterIndex: chapterIndex,
          anchor: ReaderPositionAnchor(
            chapterUrl: chapters[chapterIndex].url,
            chapterIndex: chapterIndex,
            characterOffset: _pendingCharacterOffset,
            context: stableAnchor?.context ?? '',
          ),
          config: config,
          loadState: ReaderLoadState.loading,
          clearError: true,
        ),
      );
      _subscribeBookmarks(book);
      _effectController.add(EnterReaderSystemEffect(config));
      await _loadCurrentChapter();
      _logger.info(
        tag: bookReaderEntryLogTag,
        message: '阅读器初始化完成 bookId=$bookId chapterIndex=${_state.currentChapterIndex} '
            'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } on Object catch (error, stackTrace) {
      _logger.error(
        tag: bookReaderEntryLogTag,
        message: '阅读器初始化异常 bookId=$bookId elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '初始化阅读器失败'));
    }
  }

  /// 通过稳定章节 URL 优先恢复章节，必要时回退旧索引并跳过卷标题。
  int _resolveInitialChapter(
    List<BookChapter> chapters,
    ReaderPositionAnchor? anchor,
    ReadingProgress? progress,
    int? routeChapterIndex,
  ) {
    if (routeChapterIndex != null) {
      /// 路由指定章节越界时夹取到目录范围内，避免异常中断阅读入口。
      final int routePreferred = routeChapterIndex.clamp(0, chapters.length - 1).toInt();
      if (!chapters[routePreferred].isVolume) {
        return routePreferred;
      }
      /// 路由落到卷标题时，打开其后的第一个可阅读章节。
      final int routeNext = chapters.indexWhere(
        (BookChapter chapter) => chapter.index >= routePreferred && !chapter.isVolume,
      );
      if (routeNext >= 0) {
        return routeNext;
      }
    }
    if (anchor != null) {
      /// 与稳定章节地址完全一致的位置。
      final int stableIndex = chapters.indexWhere(
        (BookChapter chapter) => chapter.url == anchor.chapterUrl && !chapter.isVolume,
      );
      if (stableIndex >= 0) {
        return stableIndex;
      }
    }
    /// 旧进度索引或书籍默认索引。
    final int preferred = (progress?.chapterIndex ?? 0).clamp(0, chapters.length - 1).toInt();
    if (!chapters[preferred].isVolume) {
      return preferred;
    }
    /// 卷标题之后的首个可阅读章节。
    final int next = chapters.indexWhere(
      (BookChapter chapter) => chapter.index >= preferred && !chapter.isVolume,
    );
    if (next >= 0) {
      return next;
    }
    /// 首个可阅读章节，初始化前已经确认一定存在。
    return chapters.indexWhere((BookChapter chapter) => !chapter.isVolume);
  }

  /// 订阅当前书名和作者关联的书签。
  void _subscribeBookmarks(Book book) {
    _bookmarkSubscription?.cancel();
    _bookmarkSubscription = _bookmarkGateway.watchByBook(book.name, book.author).listen(
      (List<Bookmark> bookmarks) {
        _emit(_state.copyWith(bookmarks: bookmarks));
      },
      onError: (Object error) {
        _effectController.add(const ShowReaderMessageEffect('读取书签失败'));
      },
    );
  }

  /// 加载当前章节并在成功后恢复字符锚点和启动相邻章预加载。
  Future<void> _loadCurrentChapter({
    bool forceRefresh = false,
    bool preserveCurrentContent = false,
  }) async {
    /// 当前书籍。
    final Book? book = _state.book;
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    if (book == null || chapter == null) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '章节加载被拒绝 hasBook=${book != null} hasChapter=${chapter != null}',
      );
      return;
    }
    _loadGeneration += 1;
    /// 本次章节加载世代。
    final int generation = _loadGeneration;
    /// 【搜书诊断日志】当前章节不可逆标识。
    final String chapterId = appLogDiagnosticId(chapter.url);
    /// 【搜书诊断日志】当前章节从 ViewModel 发起到可渲染的耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '可见章节加载开始 generation=$generation chapterId=$chapterId '
          'chapterIndex=${_state.currentChapterIndex} forceRefresh=$forceRefresh',
    );
    _emit(
      _state.copyWith(
        loadState: ReaderLoadState.loading,
        clearContent: !preserveCurrentContent,
        clearError: true,
        menuVisible: preserveCurrentContent ? false : true,
      ),
    );
    try {
      /// 处理完成的章节正文。
      final ReaderChapterContent content = await _coordinator.loadChapter(
        book: book,
        chapter: chapter,
        config: _state.config,
        forceRefresh: forceRefresh,
      );
      if (_disposed || generation != _loadGeneration || _state.currentChapter?.url != chapter.url) {
        _logger.debug(
          tag: bookReaderContentLogTag,
          message: '忽略旧章节结果 generation=$generation currentGeneration=$_loadGeneration '
              'chapterId=$chapterId disposed=$_disposed',
        );
        return;
      }
      /// 根据附近正文修正正文变化后的字符位置。
      final int restoredOffset = _relocateAnchor(content.text, _state.anchor);
      _pendingCharacterOffset = restoredOffset;
      /// 已修正的稳定锚点。
      final ReaderPositionAnchor anchor = _buildAnchor(chapter, content.text, restoredOffset);
      _emit(
        _state.copyWith(
          content: content,
          anchor: anchor,
          loadState: ReaderLoadState.ready,
          searchState: const ReaderSearchState(),
          restoreRequestId: _state.restoreRequestId + 1,
          clearError: true,
        ),
      );
      _logger.info(
        tag: bookReaderContentLogTag,
        message: '可见章节加载完成 generation=$generation chapterId=$chapterId '
            'textLength=${content.text.length} fromCache=${content.fromCache} '
            'restoredOffset=$restoredOffset elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      unawaited(_cacheGateway.savePositionAnchor(bookUrl, anchor));
      unawaited(
        _coordinator.preloadAdjacent(
          book: book,
          chapters: _state.chapters,
          currentIndex: _state.currentChapterIndex,
          config: _state.config,
        ),
      );
    } on ReadBookException catch (error) {
      if (generation == _loadGeneration) {
        _logger.error(
          tag: bookReaderContentLogTag,
          message: '可见章节加载失败 generation=$generation chapterId=$chapterId '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
        );
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: error.message));
      }
    } on Object catch (error, stackTrace) {
      if (generation == _loadGeneration) {
        _logger.error(
          tag: bookReaderContentLogTag,
          message: '可见章节加载异常 generation=$generation chapterId=$chapterId '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '加载章节正文失败'));
      }
    }
  }

  /// 用锚点附近正文在变化后的章节中重新定位，否则使用受控字符位置。
  int _relocateAnchor(String text, ReaderPositionAnchor? anchor) {
    if (text.isEmpty || anchor == null) {
      return 0;
    }
    /// 旧位置限制在新正文范围内。
    final int fallback = anchor.characterOffset.clamp(0, math.max(0, text.length - 1)).toInt();
    if (anchor.context.isEmpty) {
      return fallback;
    }
    /// 先在旧位置前后 2000 字内查找摘要，降低重复段落误定位。
    final int start = math.max(0, fallback - 2000);
    final int end = math.min(text.length, fallback + 2000 + anchor.context.length);
    final int local = text.substring(start, end).indexOf(anchor.context);
    if (local >= 0) {
      return start + local;
    }
    /// 局部未找到时再尝试整章搜索。
    final int global = text.indexOf(anchor.context);
    return global >= 0 ? global : fallback;
  }

  /// 记录滚动字符位置，并分别节流状态更新和持久进度写入。
  void _updateScroll(int characterOffset) {
    /// 当前正文长度。
    final int textLength = _state.content?.text.length ?? 0;
    _pendingCharacterOffset = characterOffset.clamp(0, math.max(0, textLength - 1)).toInt();
    _anchorUpdateTimer?.cancel();
    _anchorUpdateTimer = Timer(const Duration(milliseconds: 250), _commitPendingAnchor);
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_saveProgress());
    });
  }

  /// 将最近滚动位置转换为带上下文的稳定状态锚点。
  void _commitPendingAnchor() {
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    /// 当前正文。
    final String? text = _state.content?.text;
    if (chapter == null || text == null) {
      return;
    }
    _emit(_state.copyWith(anchor: _buildAnchor(chapter, text, _pendingCharacterOffset)));
  }

  /// 创建包含稳定章节 URL、字符位置和短上下文的锚点。
  ReaderPositionAnchor _buildAnchor(BookChapter chapter, String text, int characterOffset) {
    /// 受控字符位置。
    final int offset = characterOffset.clamp(0, math.max(0, text.length - 1)).toInt();
    /// 摘要起点与字符位置一致，便于恢复首个可见内容。
    final int contextEnd = math.min(text.length, offset + 80);
    return ReaderPositionAnchor(
      chapterUrl: chapter.url,
      chapterIndex: _state.currentChapterIndex,
      characterOffset: offset,
      context: text.substring(offset, contextEnd),
    );
  }

  /// 切换到指定方向的下一可阅读章节。
  Future<void> _openRelativeChapter(int direction) async {
    if (_changingRelativeChapter) {
      return;
    }
    _changingRelativeChapter = true;
    /// 【搜书诊断日志】记录上下章操作和当前索引。
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '用户切换相邻章节 direction=$direction currentIndex=${_state.currentChapterIndex}',
    );
    try {
      /// 查找中的章节索引。
      int index = _state.currentChapterIndex + direction;
      while (index >= 0 && index < _state.chapters.length) {
        if (!_state.chapters[index].isVolume) {
          /// 向上进入上一章时从章尾恢复，向下进入下一章时从章首开始。
          final int characterOffset = direction < 0 ? 0x7FFFFFFF : 0;
          await _openChapter(
            index,
            characterOffset: characterOffset,
            preserveCurrentContent: true,
            transitionDirection: direction,
          );
          return;
        }
        index += direction;
      }
      _effectController.add(
        ShowReaderMessageEffect(direction > 0 ? '已经是最后一章' : '已经是第一章'),
      );
    } finally {
      _changingRelativeChapter = false;
    }
  }

  /// 保存当前章后打开目标章节，切换时字符位置默认从章首开始。
  Future<void> _openChapter(
    int chapterIndex, {
    int characterOffset = 0,
    bool preserveCurrentContent = false,
    int transitionDirection = 0,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= _state.chapters.length) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '打开章节被拒绝 reason=indexOutOfRange targetIndex=$chapterIndex '
            'chapterCount=${_state.chapters.length}',
      );
      _effectController.add(const ShowReaderMessageEffect('目标章节不存在'));
      return;
    }
    /// 目标章节。
    final BookChapter chapter = _state.chapters[chapterIndex];
    if (chapter.isVolume) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '打开章节被拒绝 reason=volumeTitle targetIndex=$chapterIndex',
      );
      _effectController.add(const ShowReaderMessageEffect('卷标题不能直接阅读'));
      return;
    }
    await _saveProgress();
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '打开目标章节 targetIndex=$chapterIndex '
          'chapterId=${appLogDiagnosticId(chapter.url)} characterOffset=$characterOffset',
    );
    _pendingCharacterOffset = math.max(0, characterOffset);
    _emit(
      _state.copyWith(
        currentChapterIndex: chapterIndex,
        anchor: ReaderPositionAnchor(
          chapterUrl: chapter.url,
          chapterIndex: chapterIndex,
          characterOffset: _pendingCharacterOffset,
          context: '',
        ),
        searchState: const ReaderSearchState(),
        chapterTransitionDirection: transitionDirection,
        clearSheet: true,
      ),
    );
    await _loadCurrentChapter(preserveCurrentContent: preserveCurrentContent);
  }

  /// 更新搜索词并清理旧结果，避免用户改词后继续显示过期匹配。
  void _updateSearchQuery(String query) {
    _emit(
      _state.copyWith(
        searchState: ReaderSearchState(
          query: query,
          scope: _state.searchState.scope,
        ),
      ),
    );
  }

  /// 更新搜索范围并保留当前输入词。
  void _updateSearchScope(ReaderSearchScope scope) {
    _emit(
      _state.copyWith(
        searchState: _state.searchState.copyWith(
          scope: scope,
          matches: const <ReaderSearchMatch>[],
          currentIndex: 0,
          submitted: false,
          searching: false,
        ),
      ),
    );
  }

  /// 在当前章节或整本书正文内执行简单文本搜索。
  Future<void> _submitSearch() async {
    /// 当前搜索词。
    final String query = _state.searchState.query.trim();
    if (query.isEmpty) {
      _emit(
        _state.copyWith(
          searchState: _state.searchState.copyWith(
            matches: const <ReaderSearchMatch>[],
            currentIndex: 0,
            submitted: true,
            searching: false,
          ),
        ),
      );
      _effectController.add(const ShowReaderMessageEffect('请输入搜索内容'));
      return;
    }
    _searchGeneration += 1;
    /// 本次搜索世代。
    final int generation = _searchGeneration;
    /// 当前搜索范围。
    final ReaderSearchScope scope = _state.searchState.scope;
    _emit(
      _state.copyWith(
        searchState: _state.searchState.copyWith(
          query: query,
          matches: const <ReaderSearchMatch>[],
          currentIndex: 0,
          submitted: true,
          searching: true,
        ),
      ),
    );
    /// 收集到的匹配结果。
    final List<ReaderSearchMatch> matches = scope == ReaderSearchScope.wholeBook
        ? await _searchWholeBook(query, generation)
        : _searchText(
            query: query,
            text: _state.content?.text ?? '',
            chapterIndex: _state.currentChapterIndex,
            chapterTitle: _state.currentChapter?.title ?? '',
          );
    if (_disposed || generation != _searchGeneration) {
      return;
    }
    if (matches.isEmpty && (_state.content?.text ?? '').isEmpty && scope == ReaderSearchScope.currentChapter) {
      _emit(
        _state.copyWith(
          searchState: _state.searchState.copyWith(
            query: query,
            matches: const <ReaderSearchMatch>[],
            currentIndex: 0,
            submitted: true,
            searching: false,
          ),
        ),
      );
      _effectController.add(const ShowReaderMessageEffect('当前章节没有可搜索正文'));
      return;
    }
    _emit(
      _state.copyWith(
        searchState: _state.searchState.copyWith(
          query: query,
          matches: matches,
          currentIndex: 0,
          submitted: true,
          searching: false,
        ),
      ),
    );
    if (matches.isEmpty) {
      _effectController.add(
        ShowReaderMessageEffect(
          scope == ReaderSearchScope.wholeBook ? '整本书没有匹配结果' : '当前章节没有匹配结果',
        ),
      );
      return;
    }
    await _openSearchResult(0);
  }

  /// 搜索整本书的全部可阅读章节，遇到失败章节时继续处理后续章节。
  Future<List<ReaderSearchMatch>> _searchWholeBook(String query, int generation) async {
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null) {
      return const <ReaderSearchMatch>[];
    }
    /// 整书搜索收集到的匹配项。
    final List<ReaderSearchMatch> matches = <ReaderSearchMatch>[];
    for (int index = 0; index < _state.chapters.length; index += 1) {
      if (_disposed || generation != _searchGeneration) {
        break;
      }
      /// 当前搜索章节。
      final BookChapter chapter = _state.chapters[index];
      if (chapter.isVolume) {
        continue;
      }
      try {
        /// 当前可见章节已经加载好的正文。
        final ReaderChapterContent? visibleContent = _state.content;
        /// 当前章节正文，当前章优先复用已经渲染的内容。
        final ReaderChapterContent content = index == _state.currentChapterIndex && visibleContent != null
            ? visibleContent
            : await _coordinator.loadChapter(
                book: book,
                chapter: chapter,
                config: _state.config,
              );
        matches.addAll(
          _searchText(
            query: query,
            text: content.text,
            chapterIndex: index,
            chapterTitle: chapter.title,
          ),
        );
      } on Object catch (error) {
        _logger.warning(
          tag: bookReaderContentLogTag,
          message: '整书搜索跳过失败章节 chapterIndex=$index '
              'chapterId=${appLogDiagnosticId(chapter.url)}',
          error: error,
        );
      }
    }
    return matches;
  }

  /// 在指定文本中搜索关键词，并附带章节定位信息。
  List<ReaderSearchMatch> _searchText({
    required String query,
    required String text,
    required int chapterIndex,
    required String chapterTitle,
  }) {
    if (text.isEmpty) {
      return const <ReaderSearchMatch>[];
    }
    /// 小写后的正文，用于英文大小写不敏感匹配。
    final String normalizedText = text.toLowerCase();
    /// 小写后的搜索词。
    final String normalizedQuery = query.toLowerCase();
    /// 收集到的匹配结果。
    final List<ReaderSearchMatch> matches = <ReaderSearchMatch>[];
    /// 当前搜索起点。
    int start = 0;
    while (start < normalizedText.length) {
      /// 本次命中的字符位置。
      final int found = normalizedText.indexOf(normalizedQuery, start);
      if (found < 0) {
        break;
      }
      matches.add(
        ReaderSearchMatch(
          start: found,
          end: found + query.length,
          preview: _searchPreview(text, found, found + query.length),
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
        ),
      );
      start = found + math.max(1, query.length);
    }
    return matches;
  }

  /// 截取搜索结果前后的短预览。
  String _searchPreview(String text, int start, int end) {
    /// 预览起点。
    final int previewStart = math.max(0, start - 28);
    /// 预览终点。
    final int previewEnd = math.min(text.length, end + 42);
    /// 原始预览文本。
    final String raw = text.substring(previewStart, previewEnd);
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 打开指定搜索结果。
  Future<void> _openSearchResult(int index) async {
    /// 当前匹配列表。
    final List<ReaderSearchMatch> matches = _state.searchState.matches;
    if (index < 0 || index >= matches.length) {
      return;
    }
    /// 跳转前保留搜索状态，跨章节打开会重置当前章搜索状态。
    final ReaderSearchState searchState = _state.searchState;
    _emit(
      _state.copyWith(
        searchState: searchState.copyWith(currentIndex: index),
      ),
    );
    /// 当前命中的搜索结果。
    final ReaderSearchMatch match = matches[index];
    /// 命中的章节索引；旧当前章结果为空时回退当前索引。
    final int targetChapterIndex = match.chapterIndex ?? _state.currentChapterIndex;
    if (targetChapterIndex != _state.currentChapterIndex) {
      await _openChapter(targetChapterIndex, characterOffset: match.start);
      _emit(
        _state.copyWith(
          activeSheet: const ReaderSearchSheet(),
          searchState: searchState.copyWith(currentIndex: index),
        ),
      );
      return;
    }
    _jumpToCharacterOffset(match.start);
  }

  /// 按前后方向切换搜索结果。
  Future<void> _navigateSearchResult(int direction) async {
    /// 当前匹配列表。
    final List<ReaderSearchMatch> matches = _state.searchState.matches;
    if (matches.isEmpty || direction == 0) {
      return;
    }
    /// 环形切换后的目标结果索引。
    final int target = (_state.searchState.currentIndex + direction) % matches.length;
    /// Dart 负数取余仍为非负结果，此变量保留可读的合法索引。
    final int normalizedTarget = target < 0 ? target + matches.length : target;
    await _openSearchResult(normalizedTarget);
  }

  /// 跳转到当前章节内指定字符位置并保存稳定锚点。
  void _jumpToCharacterOffset(int characterOffset) {
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    /// 当前正文。
    final String? text = _state.content?.text;
    if (chapter == null || text == null) {
      return;
    }
    _pendingCharacterOffset = characterOffset.clamp(0, math.max(0, text.length - 1)).toInt();
    _emit(
      _state.copyWith(
        anchor: _buildAnchor(chapter, text, _pendingCharacterOffset),
        restoreRequestId: _state.restoreRequestId + 1,
        menuVisible: false,
      ),
    );
    unawaited(_saveProgress());
  }

  /// 保存书籍兼容进度和包含章节 URL 的稳定正文锚点。
  Future<void> _saveProgress() async {
    _anchorUpdateTimer?.cancel();
    _progressSaveTimer?.cancel();
    _commitPendingAnchor();
    /// 当前书籍。
    final Book? book = _state.book;
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    /// 当前锚点。
    final ReaderPositionAnchor? anchor = _state.anchor;
    if (book == null || chapter == null || anchor == null) {
      return;
    }
    /// 当前毫秒时间戳。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 兼容 books 表的进度更新结果。
    final AppResult<bool> result = await _saveReadingProgress.execute(
      ReadingProgress(
        bookUrl: book.bookUrl,
        chapterIndex: _state.currentChapterIndex,
        chapterPos: anchor.characterOffset,
        readTime: now,
        chapterTitle: chapter.title,
        syncTime: book.syncTime,
      ),
    );
    await _cacheGateway.savePositionAnchor(bookUrl, anchor);
    if (result is AppFailure<bool>) {
      _logger.error(
        tag: bookReaderEntryLogTag,
        message: '阅读进度保存失败 bookId=${appLogDiagnosticId(bookUrl)} '
            'chapterIndex=${_state.currentChapterIndex}',
        error: result.error,
      );
      _effectController.add(ShowReaderMessageEffect(result.error.message));
    } else {
      /// 【搜书诊断日志】滚动节流后只记录稳定位置，不记录正文摘要。
      _logger.debug(
        tag: bookReaderEntryLogTag,
        message: '阅读进度保存成功 bookId=${appLogDiagnosticId(bookUrl)} '
            'chapterIndex=${_state.currentChapterIndex} characterOffset=${anchor.characterOffset}',
      );
    }
  }

  /// 保存配置；排版相关字段变化后按字符锚点重新定位，替换开关变化时重新处理正文。
  Future<void> _updateConfig(ReaderDisplayConfig config) async {
    /// 旧配置。
    final ReaderDisplayConfig previous = _state.config;
    _emit(
      _state.copyWith(
        config: config,
        restoreRequestId: _state.restoreRequestId + 1,
      ),
    );
    await _cacheGateway.saveDisplayConfig(bookUrl, config);
    if (previous.keepScreenOn != config.keepScreenOn ||
        previous.useSystemBrightness != config.useSystemBrightness ||
        previous.readerBrightness != config.readerBrightness ||
        previous.orientationMode != config.orientationMode) {
      _effectController.add(UpdateReaderSystemEffect(config));
    }
    if (previous.useReplaceRules != config.useReplaceRules) {
      await _loadCurrentChapter();
      return;
    }
    if (previous.preDownloadCount != config.preDownloadCount) {
      /// 当前书籍事实。
      final Book? book = _state.book;
      if (book != null && _state.loadState == ReaderLoadState.ready) {
        unawaited(
          _coordinator.preloadAdjacent(
            book: book,
            chapters: _state.chapters,
            currentIndex: _state.currentChapterIndex,
            config: config,
          ),
        );
      }
    }
  }

  /// 在当前首个可见字符位置创建 Android 兼容书签。
  Future<void> _addBookmark() async {
    /// 当前书籍。
    final Book? book = _state.book;
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    /// 当前正文。
    final String? text = _state.content?.text;
    if (book == null || chapter == null || text == null) {
      return;
    }
    /// 当前受控字符位置。
    final int offset = _pendingCharacterOffset.clamp(0, math.max(0, text.length - 1)).toInt();
    /// 书签附近正文终点。
    final int end = math.min(text.length, offset + 120);
    /// 书签摘要。
    final String excerpt = text.substring(offset, end);
    await _bookmarkGateway.saveBookmark(
      Bookmark(
        time: DateTime.now().millisecondsSinceEpoch,
        bookName: book.name,
        bookAuthor: book.author,
        chapterIndex: _state.currentChapterIndex,
        chapterPos: offset,
        chapterName: chapter.title,
        bookText: excerpt,
        content: excerpt,
      ),
    );
    _effectController.add(const ShowReaderMessageEffect('书签已添加'));
  }

  /// 删除指定书签并保留当前阅读位置。
  Future<void> _deleteBookmark(Bookmark bookmark) async {
    await _bookmarkGateway.deleteBookmark(bookmark.time);
    _effectController.add(const ShowReaderMessageEffect('书签已删除'));
  }

  /// 保存用户修改后的书签备注。
  Future<void> _saveBookmarkNote(Bookmark bookmark, String content) async {
    /// 规范化后的备注文本。
    final String normalizedContent = content.trim();
    /// 空备注回退到创建书签时的正文摘要。
    final String nextContent = normalizedContent.isEmpty ? bookmark.bookText : normalizedContent;
    await _bookmarkGateway.saveBookmark(
      Bookmark(
        time: bookmark.time,
        bookName: bookmark.bookName,
        bookAuthor: bookmark.bookAuthor,
        chapterIndex: bookmark.chapterIndex,
        chapterPos: bookmark.chapterPos,
        chapterName: bookmark.chapterName,
        bookText: bookmark.bookText,
        content: nextContent,
      ),
    );
    _emit(_state.copyWith(clearSheet: true));
    _effectController.add(const ShowReaderMessageEffect('书签备注已保存'));
  }

  /// 把当前书签列表整理成可读文本并请求路由复制到剪贴板。
  void _exportBookmarks() {
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null) {
      return;
    }
    if (_state.bookmarks.isEmpty) {
      _effectController.add(const ShowReaderMessageEffect('还没有可导出的书签'));
      return;
    }
    /// 导出文本行集合。
    final List<String> lines = <String>[
      '# ${book.name}',
      '',
    ];
    for (final Bookmark bookmark in _state.bookmarks) {
      lines.add('## ${bookmark.chapterName}');
      lines.add('- 位置：${bookmark.chapterPos}');
      if (bookmark.bookText.isNotEmpty) {
        lines.add('- 原文：${bookmark.bookText.replaceAll(RegExp(r'\s+'), ' ').trim()}');
      }
      if (bookmark.content.isNotEmpty && bookmark.content != bookmark.bookText) {
        lines.add('- 备注：${bookmark.content.replaceAll(RegExp(r'\s+'), ' ').trim()}');
      }
      lines.add('');
    }
    _effectController.add(
      CopyReaderTextEffect(
        text: lines.join('\n'),
        message: '已复制 ${_state.bookmarks.length} 条书签到剪贴板',
      ),
    );
  }

  /// 读取并展示当前书可用的完整正文替换规则列表。
  Future<void> _loadReplaceRules() async {
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null) {
      return;
    }
    try {
      /// 适用于当前书名或书源的启用正文规则。
      final List<ReplaceRule> rules = await _replaceRuleGateway.getEnabledContentRules(
        book.name,
        book.origin,
      );
      if (_disposed) {
        return;
      }
      _emit(_state.copyWith(replaceRules: rules));
    } on Object catch (error, stackTrace) {
      _logger.error(
        tag: bookReaderContentLogTag,
        message: '替换规则列表读取失败 bookId=${appLogDiagnosticId(bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
      _effectController.add(const ShowReaderMessageEffect('读取替换规则失败'));
    }
  }

  /// 按范围后台强制刷新章节缓存；当前章刷新后立即回填可见正文。
  Future<void> _refreshChapters(ReaderRefreshScope scope) async {
    if (_state.refreshingChapters && scope != ReaderRefreshScope.currentChapter) {
      _effectController.add(const ShowReaderMessageEffect('章节刷新正在进行'));
      return;
    }
    if (scope == ReaderRefreshScope.currentChapter) {
      await _loadCurrentChapter(forceRefresh: true, preserveCurrentContent: true);
      return;
    }
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null) {
      return;
    }
    _refreshGeneration += 1;
    /// 本次刷新世代。
    final int generation = _refreshGeneration;
    /// 需要刷新的章节索引。
    final List<int> indexes = _refreshIndexes(scope);
    if (indexes.isEmpty) {
      _effectController.add(const ShowReaderMessageEffect('没有需要刷新的章节'));
      return;
    }
    _emit(_state.copyWith(refreshingChapters: true));
    _effectController.add(
      ShowReaderMessageEffect(
        scope == ReaderRefreshScope.followingChapters ? '开始刷新后续章节' : '开始刷新全部章节',
      ),
    );
    /// 成功刷新的章节数。
    int successCount = 0;
    for (final int index in indexes) {
      if (_disposed || generation != _refreshGeneration) {
        break;
      }
      /// 当前刷新章节。
      final BookChapter chapter = _state.chapters[index];
      try {
        await _coordinator.loadChapter(
          book: book,
          chapter: chapter,
          config: _state.config,
          forceRefresh: true,
        );
        successCount += 1;
      } on Object catch (error) {
        _logger.warning(
          tag: bookReaderContentLogTag,
          message: '后台刷新章节失败 chapterIndex=$index '
              'chapterId=${appLogDiagnosticId(chapter.url)}',
          error: error,
        );
      }
    }
    if (_disposed || generation != _refreshGeneration) {
      return;
    }
    _emit(_state.copyWith(refreshingChapters: false));
    _effectController.add(
      ShowReaderMessageEffect('章节刷新完成：$successCount / ${indexes.length}'),
    );
  }

  /// 根据用户选择的刷新范围生成可阅读章节索引。
  List<int> _refreshIndexes(ReaderRefreshScope scope) {
    /// 起始目录索引。
    final int startIndex = switch (scope) {
      ReaderRefreshScope.currentChapter => _state.currentChapterIndex,
      ReaderRefreshScope.followingChapters => _state.currentChapterIndex + 1,
      ReaderRefreshScope.allChapters => 0,
    };
    /// 收集到的章节索引。
    final List<int> indexes = <int>[];
    for (int index = startIndex; index < _state.chapters.length; index += 1) {
      if (!_state.chapters[index].isVolume) {
        indexes.add(index);
      }
    }
    return indexes;
  }

  /// 保存当前稳定进度并请求路由进入整书换源，避免旧主键删除前丢失最后位置。
  Future<void> _requestBookSourceChange() async {
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null || book.origin == 'loc_book') {
      _effectController.add(const ShowReaderMessageEffect('当前书籍不支持整书换源'));
      return;
    }
    await _saveProgress();
    _emit(_state.copyWith(menuVisible: false));
    _effectController.add(OpenReaderBookSourceChangeEffect(book.bookUrl));
  }

  /// 把单章换源候选正文写入目标章节永久缓存，使其不再受 7 天普通缓存有效期约束；
  /// 目标章节正是当前可见章节时清除内存缓存并立即重新加载，让新正文马上显示。
  Future<void> _saveChapterSourceContent(int chapterIndex, String content) async {
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null || chapterIndex < 0 || chapterIndex >= _state.chapters.length) {
      _emit(_state.copyWith(clearSheet: true));
      return;
    }
    /// 待替换正文的目标章节。
    final BookChapter chapter = _state.chapters[chapterIndex];
    try {
      await _cacheGateway.saveChapterContent(book.bookUrl, chapter.url, content, 0);
      _coordinator.invalidateChapter(chapter.url);
      _logger.info(
        tag: bookSourceChangeLogTag,
        message: '单章换源正文已保存 bookId=${appLogDiagnosticId(bookUrl)} '
            'chapterId=${appLogDiagnosticId(chapter.url)} contentLength=${content.length}',
      );
      _emit(_state.copyWith(clearSheet: true));
      if (chapterIndex == _state.currentChapterIndex) {
        await _loadCurrentChapter(preserveCurrentContent: true);
      }
      _effectController.add(const ShowReaderMessageEffect('单章换源已完成'));
    } on Object catch (error, stackTrace) {
      _logger.error(
        tag: bookSourceChangeLogTag,
        message: '单章换源正文保存失败 bookId=${appLogDiagnosticId(bookUrl)} '
            'chapterId=${appLogDiagnosticId(chapter.url)}',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(_state.copyWith(clearSheet: true));
      _effectController.add(const ShowReaderMessageEffect('单章换源保存失败'));
    }
  }

  /// 正常退出前立即保存进度并恢复平台窗口状态。
  Future<void> _close() async {
    await _saveProgress();
    _effectController.add(const ExitReaderSystemEffect());
    _effectController.add(const CloseReaderRouteEffect());
  }

  /// 发布新状态；释放后不再写入关闭的流。
  void _emit(ReaderUiState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    _stateController.add(state);
  }

  /// 取消定时器、订阅、正文请求并关闭页面流。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _logger.info(
      tag: bookReaderEntryLogTag,
      message: '阅读器资源释放 bookId=${appLogDiagnosticId(bookUrl)} '
          'chapterIndex=${_state.currentChapterIndex}',
    );
    _anchorUpdateTimer?.cancel();
    _progressSaveTimer?.cancel();
    _bookmarkSubscription?.cancel();
    _refreshGeneration += 1;
    _searchGeneration += 1;
    _coordinator.dispose();
    _stateController.close();
    _effectController.close();
  }
}
