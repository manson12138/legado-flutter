import 'dart:async';
import 'dart:math' as math;

import '../../domain/gateway/bookmark_gateway.dart';
import '../../domain/gateway/book_content_process_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/reading_history_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/gateway/replace_rule_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/book_content_process.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/reading_progress.dart';
import '../../domain/model/replace_rule.dart';
import '../../domain/usecase/load_book_chapters_use_case.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../domain/usecase/record_reading_history_use_case.dart';
import '../../domain/usecase/restore_reading_progress_use_case.dart';
import '../../domain/usecase/save_reading_progress_use_case.dart';
import '../../domain/usecase/save_book_content_process_use_case.dart';
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
    this.initialBook,
    this.initialIsInBookshelf,
    this.initialChapters = const <BookChapter>[],
    required ReaderDisplayConfig initialDisplayConfig,
    required bool initialShowIntroPage,
    required bool initialMenuVisible,
    required void Function() markIntroSeen,
    required void Function() markInitialMenuShown,
    this.entry = 'bookshelf',
    required BookshelfGateway bookshelfGateway,
    required ReadingHistoryGateway readingHistoryGateway,
    required LoadBookChaptersUseCase loadBookChapters,
    required RestoreReadingProgressUseCase restoreReadingProgress,
    required SaveReadingProgressUseCase saveReadingProgress,
    required BookmarkGateway bookmarkGateway,
    required BookContentProcessGateway bookContentProcessGateway,
    required ReplaceRuleGateway replaceRuleGateway,
    required ReaderCacheGateway cacheGateway,
    required ReadBookCoordinator coordinator,
    required SaveBookContentProcessUseCase saveBookContentProcess,
    required RecordReadingHistoryUseCase recordReadingHistory,
    required AddBookToBookshelfUseCase addBookToBookshelf,
    required Future<void> Function(
      String eventName, {
      Map<String, Object?> props,
    }) analyticsRecorder,
    required AppLogger logger,
  }) : _bookshelfGateway = bookshelfGateway,
       _readingHistoryGateway = readingHistoryGateway,
       _loadBookChapters = loadBookChapters,
       _restoreReadingProgress = restoreReadingProgress,
       _saveReadingProgress = saveReadingProgress,
       _bookmarkGateway = bookmarkGateway,
       _bookContentProcessGateway = bookContentProcessGateway,
       _replaceRuleGateway = replaceRuleGateway,
       _cacheGateway = cacheGateway,
       _coordinator = coordinator,
       _saveBookContentProcess = saveBookContentProcess,
       _recordReadingHistory = recordReadingHistory,
       _addBookToBookshelf = addBookToBookshelf,
       _analyticsRecorder = analyticsRecorder,
       _markIntroSeen = markIntroSeen,
       _markInitialMenuShown = markInitialMenuShown,
       _logger = logger {
    /// 只接受主键匹配的路由书籍快照，避免错误参数污染首帧。
    final Book? routeBook =
        initialBook?.bookUrl == bookUrl ? initialBook : null;
    /// 只接受全部属于当前书籍的目录快照。
    final List<BookChapter> routeChapters =
        initialChapters.isNotEmpty &&
            initialChapters.every(
              (BookChapter chapter) => chapter.bookUrl == bookUrl,
            )
        ? initialChapters
        : const <BookChapter>[];
    /// 首帧优先使用明确路由章节，其次使用书籍快照中的稳定旧索引。
    final int requestedChapterIndex =
        initialChapterIndex ?? routeBook?.durChapterIndex ?? 0;
    /// 有目录快照时立即收窄索引；无目录时先保留非负值供恢复壳展示。
    final int shellChapterIndex = routeChapters.isEmpty
        ? math.max(0, requestedChapterIndex)
        : requestedChapterIndex
              .clamp(0, routeChapters.length - 1)
              .toInt();
    _state = ReaderUiState(
      book: routeBook,
      chapters: routeChapters,
      currentChapterIndex: shellChapterIndex,
      config: initialDisplayConfig,
      isInBookshelf: initialIsInBookshelf ?? false,
      showIntroPage: initialShowIntroPage,
      menuVisible: initialMenuVisible,
    );
    _introRequiresPersistence = initialShowIntroPage;
    _menuAutoShowRequiresPersistence = initialMenuVisible;
  }

  /// 路由提供的稳定书籍 URL。
  final String bookUrl;

  /// 详情目录入口指定的初始章节索引；为空时恢复稳定锚点或旧进度。
  final int? initialChapterIndex;

  /// 书架、历史或详情入口提供的书籍快照。
  final Book? initialBook;

  /// 路由入口已经确认的书架成员事实；为空时初始化期间并行补查。
  final bool? initialIsInBookshelf;

  /// 详情页直接阅读时提供的未入架目录快照。
  final List<BookChapter> initialChapters;

  /// 阅读入口的受控匿名埋点枚举。
  final String entry;

  /// 书架书读取边界。
  final BookshelfGateway _bookshelfGateway;

  /// 与书架独立的阅读历史数据边界。
  final ReadingHistoryGateway _readingHistoryGateway;

  /// 持久目录读取 UseCase。
  final LoadBookChaptersUseCase _loadBookChapters;

  /// 旧兼容进度恢复 UseCase。
  final RestoreReadingProgressUseCase _restoreReadingProgress;

  /// 章节索引和字符位置保存 UseCase。
  final SaveReadingProgressUseCase _saveReadingProgress;

  /// 书签持久化边界。
  final BookmarkGateway _bookmarkGateway;

  /// 用户正文高亮与下划线持久化边界。
  final BookContentProcessGateway _bookContentProcessGateway;

  /// 替换规则读取边界，用于展示当前书的完整可用规则列表。
  final ReplaceRuleGateway _replaceRuleGateway;

  /// 稳定锚点、正文和显示配置缓存边界。
  final ReaderCacheGateway _cacheGateway;

  /// 对应 Android ReadBook 的正文加载协调器。
  final ReadBookCoordinator _coordinator;

  /// 从稳定正文选区创建用户标注的业务动作。
  final SaveBookContentProcessUseCase _saveBookContentProcess;

  /// 首次成功打开后记录历史快照的业务动作。
  final RecordReadingHistoryUseCase _recordReadingHistory;

  /// 阅读器悬浮按钮显式加入书架的业务动作。
  final AddBookToBookshelfUseCase _addBookToBookshelf;

  /// 用户同意后记录严格白名单匿名事件的回调。
  final Future<void> Function(
    String eventName, {
    Map<String, Object?> props,
  }) _analyticsRecorder;

  /// 正文首帧实际可见后写入当前用户与书籍对应的 MMKV 首次标记。
  final void Function() _markIntroSeen;

  /// 工具栏首次真正可见后写入设备安装周期的一次性 MMKV 标记。
  final void Function() _markInitialMenuShown;

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

  /// 当前章节正文高亮与下划线流订阅。
  StreamSubscription<List<BookContentProcess>>? _contentProcessSubscription;

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

  /// 是否正在执行入口初始化，阻止恢复页连续点击重试创建重复本地查询。
  bool _initializing = false;

  /// 当前先导页是否仍需要在正文实际可见后写入持久化标记。
  bool _introRequiresPersistence = false;

  /// 当前路由是否仍需在工具栏实际可见后提交本安装周期的一次性标记。
  bool _menuAutoShowRequiresPersistence = false;

  /// 最近一次正文未就绪滑动提示时间，避免连续手势反复创建 Snackbar。
  int _lastIntroBlockedPromptMilliseconds = 0;

  /// 最近一次可见章节从发起到内容就绪的耗时，正文首帧后用于匿名分桶。
  int _pendingReaderOpenElapsedMilliseconds = 0;

  /// 是否已经进入保存并退出流程，防止系统返回和边缘手势重复关闭路由。
  bool _closing = false;

  /// 首次打开结果是否已经记录，避免重试和切章重复产生 reader_opened。
  bool _initialOpenReported = false;

  /// 独立阅读历史书籍与目录快照是否已成功写入。
  bool _historySnapshotRecorded = false;

  /// 串行化首次可读结果的历史与埋点旁路，避免快速切章重复写入。
  bool _recordingSuccessfulOpen = false;

  /// 首次打开失败是否已经记录，避免页面重建重复产生失败事件。
  bool _initialFailureReported = false;

  /// 是否正在切换相邻章节，防止滚动边界重复通知创建并发切章。
  bool _changingRelativeChapter = false;

  /// 后台刷新章节世代，释放或再次刷新时让旧任务自然停止。
  int _refreshGeneration = 0;

  /// 整书搜索世代，避免旧搜索结果覆盖用户最新关键词。
  int _searchGeneration = 0;

  /// 相邻章节预览世代，切章、配置变化或内存压力后拒绝旧预加载回调。
  int _adjacentPreloadGeneration = 0;

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
      case AttemptEnterReaderContentIntent():
        _attemptEnterReaderContent();
      case ReaderContentBecameVisibleIntent():
        _handleReaderContentVisible();
      case UpdateReaderScrollIntent(characterOffset: final int characterOffset):
        _updateScroll(characterOffset);
      case OpenPreviousChapterIntent():
        unawaited(_openRelativeChapter(-1));
      case OpenNextChapterIntent():
        unawaited(_openRelativeChapter(1));
      case CommitReaderAdjacentPageTurnIntent(
        direction: final int direction,
      ):
        unawaited(
          _openRelativeChapter(
            direction,
            animateTransition: false,
          ),
        );
      case OpenReaderChapterIntent(
        chapterIndex: final int chapterIndex,
        characterOffset: final int characterOffset,
      ):
        unawaited(_openChapter(chapterIndex, characterOffset: characterOffset));
      case RetryReaderChapterIntent(forceRefresh: final bool forceRefresh):
        unawaited(_retryCurrentChapter(forceRefresh: forceRefresh));
      case RefreshReaderChaptersIntent(scope: final ReaderRefreshScope scope):
        unawaited(_refreshChapters(scope));
      case ToggleReaderMenuIntent():
        _emit(_state.copyWith(menuVisible: !_state.menuVisible));
      case HideReaderMenuIntent():
        if (_state.menuVisible) {
          _emit(_state.copyWith(menuVisible: false));
        }
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
      case AddReaderBookToBookshelfIntent():
        unawaited(_addCurrentBookToBookshelf());
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
        _adjacentPreloadGeneration += 1;
        _coordinator.handleMemoryPressure();
        _emit(
          _state.copyWith(
            clearPreviousChapterPreview: true,
            clearNextChapterPreview: true,
          ),
        );
      case OpenReaderBookSourceChangeIntent():
        unawaited(_requestBookSourceChange());
      case OpenReaderBookInfoIntent():
        unawaited(_requestBookInfo());
      case ShareReaderContentImageIntent(imageUrl: final String imageUrl):
        _shareContentImage(imageUrl);
      case ApplyReaderSelectionIntent(
        selection: final ReaderTextSelection selection,
        action: final ReaderSelectionAction action,
      ):
        unawaited(_applySelection(selection, action));
      case ToggleReaderContentProcessIntent(
        id: final String id,
        enabled: final bool enabled,
      ):
        unawaited(_toggleContentProcess(id, enabled));
      case DeleteReaderContentProcessIntent(id: final String id):
        unawaited(_deleteContentProcess(id));
      case SaveReaderChapterSourceContentIntent(
        chapterIndex: final int chapterIndex,
        content: final String content,
        candidateCount: final int candidateCount,
        startedAtMilliseconds: final int startedAtMilliseconds,
      ):
        unawaited(
          _saveChapterSourceContent(
            chapterIndex,
            content,
            candidateCount: candidateCount,
            startedAtMilliseconds: startedAtMilliseconds,
          ),
        );
      case CloseReaderIntent():
        // FLUTTER_REWRITE_DEBUG_LOG：所有系统返回、按钮返回和边缘返回都会进入同一关闭意图。
        _logger.info(
          tag: readerEdgeSwipeExitLogTag,
          message: '$readerEdgeSwipeExitDebugLogMarker closeIntentReceived '
              'closing=$_closing disposed=$_disposed',
        );
        unawaited(_close());
    }
  }

  /// 校验正文图片地址后请求路由打开系统保存或分享面板。
  void _shareContentImage(String imageUrl) {
    /// 从正文资源块读取的候选图片地址。
    final Uri? uri = Uri.tryParse(imageUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        !<String>{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      _effectController.add(const ShowReaderMessageEffect('正文图片地址无效'));
      return;
    }
    _effectController.add(ShareReaderContentImageEffect(uri.toString()));
  }

  /// 初始化书籍、目录、配置、稳定锚点和兼容进度。
  Future<void> _initialize() async {
    if (_initializing || _disposed) {
      return;
    }
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
    _initializing = true;
    try {
      /// 详情、书架或历史路由提供且主键匹配的书籍快照。
      final Book? routeBook =
          initialBook?.bookUrl == bookUrl ? initialBook : null;
      /// 路由提供且全部属于当前书籍的目录快照。
      final List<BookChapter> routeChapters =
          initialChapters.isNotEmpty &&
              initialChapters.every(
                (BookChapter chapter) => chapter.bookUrl == bookUrl,
              )
          ? List<BookChapter>.unmodifiable(initialChapters)
          : const <BookChapter>[];
      /// 已知书架成员时复用路由书籍；已知非成员时不查书架；未知时后台补查。
      final Future<Book?> shelfBookFuture = switch (initialIsInBookshelf) {
        true => Future<Book?>.value(routeBook),
        false => Future<Book?>.value(),
        null => _bookshelfGateway.getBook(bookUrl),
      };
      /// 只有完全缺少路由书籍快照时才并行补查历史书籍事实。
      final Future<Book?> historyBookFuture = routeBook == null
          ? _readingHistoryGateway.getHistoryBook(bookUrl)
          : Future<Book?>.value();
      /// MMKV 显示配置、稳定锚点和旧进度互不依赖，立即并行启动。
      final Future<ReaderDisplayConfig> configFuture =
          _cacheGateway.getDisplayConfig(bookUrl);
      final Future<ReaderPositionAnchor?> stableAnchorFuture =
          _cacheGateway.getPositionAnchor(bookUrl);
      final Future<AppResult<ReadingProgress?>> progressFuture =
          _restoreReadingProgress.execute(bookUrl);
      /// 书架入口在成员事实已知时同步启动目录查询，避免等待书籍查询后才开始。
      final Future<AppResult<List<BookChapter>>>? knownShelfChaptersFuture =
          routeBook != null &&
              routeChapters.isEmpty &&
              (initialIsInBookshelf == true || entry == 'bookshelf')
          ? _loadBookChapters.execute(bookUrl)
          : null;
      /// 历史入口同样并行启动自己的目录快照查询。
      final Future<List<BookChapter>>? knownHistoryChaptersFuture =
          routeBook != null &&
              routeChapters.isEmpty &&
              entry == 'history'
          ? _readingHistoryGateway.getHistoryChapters(bookUrl)
          : null;
      /// 当前精确 URL 对应的书架书；成员资格只由此查询或路由明确事实决定。
      final Book? shelfBook = await shelfBookFuture;
      /// 与书架查询同时启动的历史书籍结果。
      final Book? historyBook = await historyBookFuture;
      if (_disposed) {
        return;
      }
      /// 并行任务已经启动，此处汇合最终显示配置、稳定锚点和兼容进度。
      final ReaderDisplayConfig config = await configFuture;
      final ReaderPositionAnchor? stableAnchor =
          await stableAnchorFuture;
      final AppResult<ReadingProgress?> progressResult =
          await progressFuture;
      if (_disposed) {
        return;
      }
      /// 阅读器实际使用的书籍事实。
      final Book? book = shelfBook ?? routeBook ?? historyBook;
      if (book == null) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '阅读器初始化终止 bookId=$bookId reason=bookNotFound',
        );
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '书籍不存在或阅读历史已失效'));
        await _recordReaderOpenFailure(book: null, failureKind: 'unknown');
        return;
      }
      /// 当前入口最终确认的书架成员资格。
      final bool isInBookshelf =
          shelfBook != null || initialIsInBookshelf == true;
      /// 根据书架、详情路由或历史来源读取完整目录。
      final List<BookChapter> chapters;
      if (routeChapters.isNotEmpty) {
        chapters = routeChapters;
      } else if (isInBookshelf) {
        final AppResult<List<BookChapter>> chaptersResult =
            await (knownShelfChaptersFuture ??
                _loadBookChapters.execute(bookUrl));
        if (chaptersResult is AppFailure<List<BookChapter>>) {
          _logger.error(
            tag: bookReaderEntryLogTag,
            message: '阅读器目录读取失败 bookId=$bookId',
            error: chaptersResult.error,
          );
          _emit(
            _state.copyWith(
              book: book,
              isInBookshelf: isInBookshelf,
              loadState: ReaderLoadState.error,
              errorMessage: chaptersResult.error.message,
            ),
          );
          await _recordReaderOpenFailure(
            book: book,
            failureKind: 'decode',
          );
          return;
        }
        chapters =
            (chaptersResult as AppSuccess<List<BookChapter>>).value;
      } else {
        chapters = await (knownHistoryChaptersFuture ??
            _readingHistoryGateway.getHistoryChapters(bookUrl));
      }
      if (_disposed) {
        return;
      }
      if (chapters.isEmpty) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '阅读器初始化终止 bookId=$bookId reason=emptyToc',
        );
        _emit(
          _state.copyWith(
            book: book,
            isInBookshelf: isInBookshelf,
            loadState: ReaderLoadState.error,
            errorMessage: '书籍目录为空，请先在详情页刷新目录',
          ),
        );
        await _recordReaderOpenFailure(book: book, failureKind: 'decode');
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
        _emit(
          _state.copyWith(
            book: book,
            isInBookshelf: isInBookshelf,
            loadState: ReaderLoadState.error,
            errorMessage: '目录中没有可阅读章节',
          ),
        );
        await _recordReaderOpenFailure(book: book, failureKind: 'decode');
        return;
      }
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
          isInBookshelf: isInBookshelf,
          loadState: ReaderLoadState.loading,
          clearError: true,
        ),
      );
      _effectController.add(EnterReaderSystemEffect(config));
      await _loadCurrentChapter();
      if (_disposed) {
        return;
      }
      /// 书签和正文标注不阻塞正文首个可读页面，正文就绪后再建立订阅。
      if (_state.loadState == ReaderLoadState.ready) {
        _subscribeBookmarks(book);
        _subscribeContentProcesses(book.bookUrl, chapterIndex);
      }
      if (_state.loadState != ReaderLoadState.ready) {
        await _recordReaderOpenFailure(
          book: book,
          failureKind: 'unknown',
        );
      }
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
      await _recordReaderOpenFailure(
        book: _state.book,
        failureKind: 'unknown',
      );
    } finally {
      _initializing = false;
    }
  }

  /// 正文未就绪时保留先导页并节流提示，就绪后只切换内存状态。
  void _attemptEnterReaderContent() {
    if (!_state.showIntroPage) {
      return;
    }
    if (_state.loadState == ReaderLoadState.ready &&
        _state.content != null) {
      _emit(
        _state.copyWith(
          showIntroPage: false,
        ),
      );
      return;
    }
    /// 当前手势发生时间，用单个整数完成节流，不创建 Timer。
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastIntroBlockedPromptMilliseconds < 1200) {
      return;
    }
    _lastIntroBlockedPromptMilliseconds = now;
    _effectController.add(
      ShowReaderMessageEffect(
        _state.loadState == ReaderLoadState.error
            ? '本章加载失败，请先重试'
            : '章节正在准备，完成后即可阅读',
      ),
    );
  }

  /// 正文组件完成首帧后提交首次标记、历史快照和匿名打开事件。
  void _handleReaderContentVisible() {
    if (_state.showIntroPage ||
        _state.loadState != ReaderLoadState.ready ||
        _state.content == null) {
      return;
    }
    if (_introRequiresPersistence) {
      _introRequiresPersistence = false;
      try {
        _markIntroSeen();
      } on Object catch (error, stackTrace) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '首次阅读先导页状态保存失败',
          error: error,
          stackTrace: stackTrace,
        );
        _effectController.add(
          const ShowReaderMessageEffect('先导页状态保存失败，下次可能再次显示'),
        );
      }
    }
    if (_menuAutoShowRequiresPersistence && _state.menuVisible) {
      _menuAutoShowRequiresPersistence = false;
      try {
        _markInitialMenuShown();
      } on Object catch (error, stackTrace) {
        _logger.warning(
          tag: bookReaderEntryLogTag,
          message: '阅读器工具栏一次性展示状态保存失败',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    unawaited(
      _recordSuccessfulReaderOpen(
        _pendingReaderOpenElapsedMilliseconds,
      ),
    );
  }

  /// 重试当前章节，并在首次成功后补齐不阻塞首显的书签与正文标注订阅。
  Future<void> _retryCurrentChapter({required bool forceRefresh}) async {
    await _loadCurrentChapter(forceRefresh: forceRefresh);
    if (_disposed || _state.loadState != ReaderLoadState.ready) {
      return;
    }
    final Book? book = _state.book;
    if (book == null) {
      return;
    }
    if (_bookmarkSubscription == null) {
      _subscribeBookmarks(book);
    }
    if (_contentProcessSubscription == null) {
      _subscribeContentProcesses(
        book.bookUrl,
        _state.currentChapterIndex,
      );
    }
  }

  /// 正文首帧实际可见后记录历史快照和匿名 reader_opened 事件。
  Future<void> _recordSuccessfulReaderOpen(int elapsedMilliseconds) async {
    if (_disposed ||
        (_initialOpenReported && _historySnapshotRecorded) ||
        _recordingSuccessfulOpen) {
      return;
    }
    final Book? book = _state.book;
    final BookChapter? chapter = _state.currentChapter;
    final ReaderPositionAnchor? anchor = _state.anchor;
    if (book == null || chapter == null || anchor == null) {
      return;
    }
    _recordingSuccessfulOpen = true;
    try {
      if (!_historySnapshotRecorded) {
        final int now = DateTime.now().millisecondsSinceEpoch;
        final Book historyBook = book.copyWithProgress(
          chapterIndex: _state.currentChapterIndex,
          chapterPos: anchor.characterOffset,
          readTime: now,
          chapterTitle: chapter.title,
        );
        final AppResult<void> historyResult =
            await _recordReadingHistory.execute(
              historyBook,
              _state.chapters,
            );
        if (_disposed) {
          return;
        }
        if (historyResult is AppFailure<void>) {
          _logger.error(
            tag: bookReaderEntryLogTag,
            message:
                '阅读历史保存失败 bookId=${appLogDiagnosticId(book.bookUrl)}',
            error: historyResult.error,
          );
          _effectController.add(
            const ShowReaderMessageEffect('阅读已打开，但历史记录保存失败'),
          );
        } else {
          _historySnapshotRecorded = true;
        }
      }
      if (_initialOpenReported) {
        return;
      }
      if (_disposed) {
        return;
      }
      _initialOpenReported = true;
      try {
        await _analyticsRecorder(
          'reader_opened',
          props: <String, Object?>{
            'entry': _normalizedEntry,
            'contentKind':
                book.origin == 'loc_book' ? 'local' : 'network',
            'durationBucket': _durationBucket(elapsedMilliseconds),
          },
        );
      } on Object {
        // 匿名埋点是旁路能力，缓存或网络异常不能把可读章节改成加载失败。
      }
    } finally {
      _recordingSuccessfulOpen = false;
    }
  }

  /// 首次打开失败后记录不含书籍标识和正文的匿名失败分类。
  Future<void> _recordReaderOpenFailure({
    required Book? book,
    required String failureKind,
  }) async {
    if (_initialFailureReported || _initialOpenReported) {
      return;
    }
    _initialFailureReported = true;
    try {
      await _analyticsRecorder(
        'reader_open_failed',
        props: <String, Object?>{
          'failureKind': failureKind,
          'contentKind': book?.origin == 'loc_book' ? 'local' : 'network',
        },
      );
    } on Object {
      // 失败埋点同样不得覆盖阅读器原本已经形成的错误状态。
    }
  }

  /// 把路由入口收窄为后端白名单允许的三种枚举。
  String get _normalizedEntry {
    return <String>{'bookshelf', 'detail', 'history'}.contains(entry)
        ? entry
        : 'bookshelf';
  }

  /// 将精确耗时转换为 API 固定分桶，不上传毫秒值。
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

  /// 将当前书籍和目录显式加入书架，成功后隐藏悬浮按钮。
  Future<void> _addCurrentBookToBookshelf() async {
    if (_state.isInBookshelf || _state.addingToBookshelf) {
      return;
    }
    final Book? book = _state.book;
    if (book == null || _state.chapters.isEmpty) {
      _effectController.add(
        const ShowReaderMessageEffect('书籍或目录尚未准备完成'),
      );
      return;
    }
    /// 加入书架时使用当前可见章节和字符位置，避免写回入口时的旧进度。
    final BookChapter? chapter = _state.currentChapter;
    final ReaderPositionAnchor? anchor = _state.anchor;
    final Book shelfBook = chapter == null || anchor == null
        ? book
        : book.copyWithProgress(
            chapterIndex: _state.currentChapterIndex,
            chapterPos: anchor.characterOffset,
            readTime: DateTime.now().millisecondsSinceEpoch,
            chapterTitle: chapter.title,
          );
    _emit(_state.copyWith(addingToBookshelf: true));
    final AppResult<void> result =
        await _addBookToBookshelf.addAsNew(shelfBook, _state.chapters);
    switch (result) {
      case AppSuccess<void>():
        _emit(
          _state.copyWith(
            isInBookshelf: true,
            addingToBookshelf: false,
          ),
        );
        _effectController.add(
          const ShowReaderMessageEffect('已加入书架'),
        );
      case AppFailure<void>(error: final error):
        final Book? existing = await _bookshelfGateway.getBook(book.bookUrl);
        if (existing != null) {
          _emit(
            _state.copyWith(
              isInBookshelf: true,
              addingToBookshelf: false,
            ),
          );
          return;
        }
        _emit(_state.copyWith(addingToBookshelf: false));
        _effectController.add(ShowReaderMessageEffect(error.message));
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

  /// 订阅当前章节用户标注，并忽略切章后晚到的旧订阅数据。
  void _subscribeContentProcesses(String targetBookUrl, int chapterIndex) {
    _contentProcessSubscription?.cancel();
    _contentProcessSubscription = _bookContentProcessGateway
        .watchForChapter(targetBookUrl, chapterIndex)
        .listen(
      (List<BookContentProcess> processes) {
        if (_state.book?.bookUrl != targetBookUrl ||
            _state.currentChapterIndex != chapterIndex) {
          return;
        }
        _emit(_state.copyWith(contentProcesses: processes));
      },
      onError: (Object error) {
        _effectController.add(
          const ShowReaderMessageEffect('读取正文标注失败'),
        );
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
    _adjacentPreloadGeneration += 1;
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
        menuVisible: preserveCurrentContent ? false : _state.menuVisible,
        clearPreviousChapterPreview: true,
        clearNextChapterPreview: true,
      ),
    );
    try {
      /// 处理完成的章节正文。
      final ReaderChapterContent content = await _coordinator.loadChapter(
        book: book,
        chapter: chapter,
        config: _state.config,
        nextChapterUrl: _nextChapterUrl(chapter.index),
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
      _pendingReaderOpenElapsedMilliseconds =
          stopwatch.elapsedMilliseconds;
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
      _startAdjacentPreviewPreload(
        book: book,
        currentIndex: _state.currentChapterIndex,
        config: _state.config,
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

  /// 启动有限相邻章节预加载，并把最接近的前后章正文快照发布到 UiState。
  void _startAdjacentPreviewPreload({
    required Book book,
    required int currentIndex,
    required ReaderDisplayConfig config,
  }) {
    _adjacentPreloadGeneration += 1;
    /// 本轮相邻章节预览任务的稳定世代。
    final int generation = _adjacentPreloadGeneration;
    /// 当前目录中最接近的上一可阅读章节索引。
    final int? previousIndex = _state.previousReadableChapterIndex;
    /// 当前目录中最接近的下一可阅读章节索引。
    final int? nextIndex = _state.nextReadableChapterIndex;
    _emit(
      _state.copyWith(
        clearPreviousChapterPreview: true,
        clearNextChapterPreview: true,
      ),
    );
    unawaited(
      _coordinator.preloadAdjacent(
        book: book,
        chapters: _state.chapters,
        currentIndex: currentIndex,
        config: config,
        onChapterReady: (
          int chapterIndex,
          ReaderChapterContent content,
        ) {
          if (_disposed ||
              generation != _adjacentPreloadGeneration ||
              _state.currentChapterIndex != currentIndex ||
              _state.book?.bookUrl != book.bookUrl) {
            return;
          }
          if (chapterIndex == previousIndex) {
            _emit(
              _state.copyWith(
                previousChapterPreview: content,
              ),
            );
            return;
          }
          if (chapterIndex == nextIndex) {
            _emit(
              _state.copyWith(
                nextChapterPreview: content,
              ),
            );
          }
        },
      ),
    );
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
  Future<void> _openRelativeChapter(
    int direction, {
    bool animateTransition = true,
  }) async {
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
            animateChapterTransition: animateTransition,
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
    bool animateChapterTransition = true,
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
        contentProcesses: const <BookContentProcess>[],
        chapterTransitionDirection: transitionDirection,
        animateChapterTransition: animateChapterTransition,
        clearPreviousChapterPreview: true,
        clearNextChapterPreview: true,
        clearSheet: true,
      ),
    );
    _subscribeContentProcesses(bookUrl, chapterIndex);
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
                nextChapterUrl: _nextChapterUrl(chapter.index),
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
    try {
      await _readingHistoryGateway.updateHistoryProgress(
        bookUrl: book.bookUrl,
        chapterIndex: _state.currentChapterIndex,
        chapterPos: anchor.characterOffset,
        readTime: now,
        chapterTitle: chapter.title,
      );
    } on Object catch (error, stackTrace) {
      _logger.error(
        tag: bookReaderEntryLogTag,
        message:
            '阅读历史进度保存失败 bookId=${appLogDiagnosticId(bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
    }
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
        previous.orientationMode != config.orientationMode ||
        previous.fullScreen != config.fullScreen) {
      _effectController.add(UpdateReaderSystemEffect(config));
    }
    if (previous.useReplaceRules != config.useReplaceRules ||
        previous.chineseConversionMode != config.chineseConversionMode ||
        previous.reSegmentContent != config.reSegmentContent) {
      _coordinator.invalidateProcessingConfiguration(bookUrl);
      await _loadCurrentChapter();
      return;
    }
    if (previous.preDownloadCount != config.preDownloadCount) {
      /// 当前书籍事实。
      final Book? book = _state.book;
      if (book != null && _state.loadState == ReaderLoadState.ready) {
        _startAdjacentPreviewPreload(
          book: book,
          currentIndex: _state.currentChapterIndex,
          config: config,
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

  /// 执行选区书签、高亮或下划线，并保持当前阅读字符锚点不变。
  Future<void> _applySelection(
    ReaderTextSelection selection,
    ReaderSelectionAction action,
  ) async {
    /// 当前书籍。
    final Book? book = _state.book;
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    /// 当前处理后完整正文。
    final String? chapterText = _state.content?.text;
    if (book == null || chapter == null || chapterText == null) {
      return;
    }
    if (selection.start < 0 ||
        selection.end > chapterText.length ||
        selection.end <= selection.start) {
      _effectController.add(
        const ShowReaderMessageEffect('选区已经失效，请重新选择'),
      );
      return;
    }
    try {
      switch (action) {
        case ReaderSelectionAction.bookmark:
          await _bookmarkGateway.saveBookmark(
            Bookmark(
              time: DateTime.now().millisecondsSinceEpoch,
              bookName: book.name,
              bookAuthor: book.author,
              chapterIndex: _state.currentChapterIndex,
              chapterPos: selection.start,
              chapterName: chapter.title,
              bookText: selection.text,
              content: selection.text,
            ),
          );
          _effectController.add(
            const ShowReaderMessageEffect('选区书签已添加'),
          );
        case ReaderSelectionAction.highlight:
          await _saveBookContentProcess.execute(
            bookUrl: book.bookUrl,
            chapterIndex: _state.currentChapterIndex,
            chapterText: chapterText,
            selection: selection,
            kind: BookContentProcessKind.userHighlight,
          );
          _effectController.add(
            const ShowReaderMessageEffect('高亮已添加'),
          );
        case ReaderSelectionAction.underline:
          await _saveBookContentProcess.execute(
            bookUrl: book.bookUrl,
            chapterIndex: _state.currentChapterIndex,
            chapterText: chapterText,
            selection: selection,
            kind: BookContentProcessKind.userUnderline,
          );
          _effectController.add(
            const ShowReaderMessageEffect('下划线已添加'),
          );
      }
    } on Object {
      _effectController.add(
        const ShowReaderMessageEffect('保存选区操作失败'),
      );
    }
  }

  /// 启用或停用用户正文标注，流更新后自动重绘当前章节。
  Future<void> _toggleContentProcess(String id, bool enabled) async {
    try {
      await _bookContentProcessGateway.setEnabled(id, enabled);
    } on Object {
      _effectController.add(
        const ShowReaderMessageEffect('更新正文标注失败'),
      );
    }
  }

  /// 软删除用户正文标注，保留同步与冲突处理所需记录。
  Future<void> _deleteContentProcess(String id) async {
    try {
      await _bookContentProcessGateway.delete(id);
      _effectController.add(
        const ShowReaderMessageEffect('正文标注已删除'),
      );
    } on Object {
      _effectController.add(
        const ShowReaderMessageEffect('删除正文标注失败'),
      );
    }
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
          nextChapterUrl: _nextChapterUrl(chapter.index),
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

  /// 读取指定目录索引的下一章 URL，供书源正文脚本使用 Android 兼容变量 `nextChapterUrl`。
  String? _nextChapterUrl(int chapterIndex) {
    /// 下一章在当前完整目录中的位置。
    final int nextIndex = chapterIndex + 1;
    if (nextIndex < 0 || nextIndex >= _state.chapters.length) {
      return _state.chapters.firstOrNull?.url;
    }
    return _state.chapters[nextIndex].url;
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

  /// 立即收起菜单并保存稳定进度，再请求路由打开书籍详情。
  Future<void> _requestBookInfo() async {
    /// 当前书籍事实。
    final Book? book = _state.book;
    if (book == null) {
      _effectController.add(const ShowReaderMessageEffect('当前书籍信息尚未就绪'));
      return;
    }
    _emit(_state.copyWith(menuVisible: false));
    await _saveProgress();
    if (_disposed) {
      return;
    }
    _effectController.add(OpenReaderBookInfoEffect(book));
  }

  /// 把单章换源候选正文写入目标章节永久缓存，使其不再受 7 天普通缓存有效期约束；
  /// 目标章节正是当前可见章节时清除内存缓存并立即重新加载，让新正文马上显示。
  Future<void> _saveChapterSourceContent(
    int chapterIndex,
    String content, {
    required int candidateCount,
    required int startedAtMilliseconds,
  }) async {
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
      _coordinator.invalidateChapter(book.bookUrl, chapter.url);
      try {
        await _analyticsRecorder(
          'chapter_source_change_completed',
          props: <String, Object?>{
            'candidateCount': candidateCount,
            'durationBucket': _durationBucket(
              DateTime.now().millisecondsSinceEpoch -
                  startedAtMilliseconds,
            ),
          },
        );
      } on Object {
        // 匿名分析失败不能覆盖永久正文缓存已经成功写入的事实。
      }
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
    if (_closing || _disposed) {
      // FLUTTER_REWRITE_DEBUG_LOG：确认重复返回是否被关闭单飞保护拦截。
      _logger.info(
        tag: readerEdgeSwipeExitLogTag,
        message: '$readerEdgeSwipeExitDebugLogMarker closeIgnored '
            'closing=$_closing disposed=$_disposed',
      );
      return;
    }
    _closing = true;
    // FLUTTER_REWRITE_DEBUG_LOG：边缘手势提交后看到该日志说明 Intent 已被 ViewModel 接受。
    _logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker closeIntentAccepted '
          'chapterIndex=${_state.currentChapterIndex} '
          'characterOffset=$_pendingCharacterOffset',
    );
    await _saveProgress();
    if (_disposed) {
      // FLUTTER_REWRITE_DEBUG_LOG：保存期间路由被释放时不再派发关闭 Effect。
      _logger.info(
        tag: readerEdgeSwipeExitLogTag,
        message: '$readerEdgeSwipeExitDebugLogMarker closeStopped '
            'reason=disposedAfterSave',
      );
      return;
    }
    // FLUTTER_REWRITE_DEBUG_LOG：保存结束后按既有顺序恢复系统状态并关闭阅读路由。
    _logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker closeEffectsEmitted',
    );
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
    _contentProcessSubscription?.cancel();
    _refreshGeneration += 1;
    _searchGeneration += 1;
    _adjacentPreloadGeneration += 1;
    _coordinator.dispose();
    _stateController.close();
    _effectController.close();
  }
}
