import 'dart:async';
import 'dart:math' as math;

import '../../domain/gateway/bookmark_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/reading_progress.dart';
import '../../domain/usecase/load_book_chapters_use_case.dart';
import '../../domain/usecase/restore_reading_progress_use_case.dart';
import '../../domain/usecase/save_reading_progress_use_case.dart';
import '../../help/error/app_result.dart';
import '../../model/reader/read_book_coordinator.dart';
import 'reader_contract.dart';

/// 管理正文加载、稳定进度、章节切换、书签、设置和预加载的阅读器 MVI ViewModel。
final class ReaderViewModel {
  /// 创建页面生命周期独占的阅读器 ViewModel。
  ReaderViewModel({
    required this.bookUrl,
    required BookshelfGateway bookshelfGateway,
    required LoadBookChaptersUseCase loadBookChapters,
    required RestoreReadingProgressUseCase restoreReadingProgress,
    required SaveReadingProgressUseCase saveReadingProgress,
    required BookmarkGateway bookmarkGateway,
    required ReaderCacheGateway cacheGateway,
    required ReadBookCoordinator coordinator,
  }) : _bookshelfGateway = bookshelfGateway,
       _loadBookChapters = loadBookChapters,
       _restoreReadingProgress = restoreReadingProgress,
       _saveReadingProgress = saveReadingProgress,
       _bookmarkGateway = bookmarkGateway,
       _cacheGateway = cacheGateway,
       _coordinator = coordinator;

  /// 路由提供的稳定书籍 URL。
  final String bookUrl;

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

  /// 稳定锚点、正文和显示配置缓存边界。
  final ReaderCacheGateway _cacheGateway;

  /// 对应 Android ReadBook 的正文加载协调器。
  final ReadBookCoordinator _coordinator;

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
      case ToggleReaderMenuIntent():
        _emit(_state.copyWith(menuVisible: !_state.menuVisible));
      case ShowReaderSheetIntent(sheet: final ReaderSheet sheet):
        _emit(_state.copyWith(activeSheet: sheet));
      case DismissReaderSheetIntent():
        _emit(_state.copyWith(clearSheet: true));
      case UpdateReaderConfigIntent(config: final ReaderDisplayConfig config):
        unawaited(_updateConfig(config));
      case AddReaderBookmarkIntent():
        unawaited(_addBookmark());
      case DeleteReaderBookmarkIntent(bookmark: final Bookmark bookmark):
        unawaited(_deleteBookmark(bookmark));
      case OpenReaderBookmarkIntent(bookmark: final Bookmark bookmark):
        _emit(_state.copyWith(clearSheet: true));
        unawaited(
          _openChapter(bookmark.chapterIndex, characterOffset: bookmark.chapterPos),
        );
      case PauseReaderIntent():
        unawaited(_saveProgress());
      case CloseReaderIntent():
        unawaited(_close());
    }
  }

  /// 初始化书籍、目录、配置、稳定锚点和兼容进度。
  Future<void> _initialize() async {
    if (bookUrl.isEmpty) {
      _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '阅读入口缺少书籍 URL'));
      return;
    }
    try {
      /// 当前书架书。
      final Book? book = await _bookshelfGateway.getBook(bookUrl);
      if (book == null) {
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '书籍已不在书架中'));
        return;
      }
      /// 持久目录读取结果。
      final AppResult<List<BookChapter>> chaptersResult = await _loadBookChapters.execute(bookUrl);
      if (chaptersResult is AppFailure<List<BookChapter>>) {
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: chaptersResult.error.message));
        return;
      }
      /// 已确认成功的目录。
      final List<BookChapter> chapters = (chaptersResult as AppSuccess<List<BookChapter>>).value;
      if (chapters.isEmpty) {
        _emit(_state.copyWith(book: book, loadState: ReaderLoadState.error, errorMessage: '书籍目录为空，请先在详情页刷新目录'));
        return;
      }
      /// 目录中是否至少存在一个可阅读章节。
      final bool hasReadableChapter = chapters.any(
        (BookChapter chapter) => !chapter.isVolume,
      );
      if (!hasReadableChapter) {
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
      /// 优先通过章节 URL 恢复，找不到时回退章节索引。
      final int chapterIndex = _resolveInitialChapter(chapters, stableAnchor, progress);
      /// 初始字符位置。
      final int characterOffset = stableAnchor?.characterOffset ?? progress?.chapterPos ?? 0;
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
      _effectController.add(EnterReaderSystemEffect(config.keepScreenOn));
      await _loadCurrentChapter();
    } on Object {
      _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: '初始化阅读器失败'));
    }
  }

  /// 通过稳定章节 URL 优先恢复章节，必要时回退旧索引并跳过卷标题。
  int _resolveInitialChapter(
    List<BookChapter> chapters,
    ReaderPositionAnchor? anchor,
    ReadingProgress? progress,
  ) {
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
  Future<void> _loadCurrentChapter({bool forceRefresh = false}) async {
    /// 当前书籍。
    final Book? book = _state.book;
    /// 当前章节。
    final BookChapter? chapter = _state.currentChapter;
    if (book == null || chapter == null) {
      return;
    }
    _loadGeneration += 1;
    /// 本次章节加载世代。
    final int generation = _loadGeneration;
    _emit(
      _state.copyWith(
        loadState: ReaderLoadState.loading,
        clearContent: true,
        clearError: true,
        menuVisible: true,
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
          restoreRequestId: _state.restoreRequestId + 1,
          clearError: true,
        ),
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
        _emit(_state.copyWith(loadState: ReaderLoadState.error, errorMessage: error.message));
      }
    } on Object {
      if (generation == _loadGeneration) {
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
    /// 查找中的章节索引。
    int index = _state.currentChapterIndex + direction;
    while (index >= 0 && index < _state.chapters.length) {
      if (!_state.chapters[index].isVolume) {
        await _openChapter(index);
        return;
      }
      index += direction;
    }
    _effectController.add(ShowReaderMessageEffect(direction > 0 ? '已经是最后一章' : '已经是第一章'));
  }

  /// 保存当前章后打开目标章节，切换时字符位置默认从章首开始。
  Future<void> _openChapter(int chapterIndex, {int characterOffset = 0}) async {
    if (chapterIndex < 0 || chapterIndex >= _state.chapters.length) {
      _effectController.add(const ShowReaderMessageEffect('目标章节不存在'));
      return;
    }
    /// 目标章节。
    final BookChapter chapter = _state.chapters[chapterIndex];
    if (chapter.isVolume) {
      _effectController.add(const ShowReaderMessageEffect('卷标题不能直接阅读'));
      return;
    }
    await _saveProgress();
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
        clearSheet: true,
      ),
    );
    await _loadCurrentChapter();
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
      _effectController.add(ShowReaderMessageEffect(result.error.message));
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
    if (previous.keepScreenOn != config.keepScreenOn) {
      _effectController.add(UpdateReaderSystemEffect(config.keepScreenOn));
    }
    if (previous.useReplaceRules != config.useReplaceRules) {
      await _loadCurrentChapter();
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
    _anchorUpdateTimer?.cancel();
    _progressSaveTimer?.cancel();
    _bookmarkSubscription?.cancel();
    _coordinator.dispose();
    _stateController.close();
    _effectController.close();
  }
}
