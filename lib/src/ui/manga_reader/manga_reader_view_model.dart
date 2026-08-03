import 'dart:async';
import 'dart:math' as math;

import '../../api/http/http_contract.dart';
import '../../api/js/js_engine.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/manga_image_gateway.dart';
import '../../domain/gateway/reading_history_gateway.dart';
import '../../domain/model/add_book_to_bookshelf_result.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/manga_chapter.dart';
import '../../domain/model/manga_page.dart';
import '../../domain/model/manga_reader_config.dart';
import '../../domain/model/manga_reading_position.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../domain/usecase/load_book_chapters_use_case.dart';
import '../../domain/usecase/record_reading_history_use_case.dart';
import '../../domain/usecase/save_reading_progress_use_case.dart';
import '../../help/error/app_result.dart';
import '../../model/analyze_rule/standard_rule_engine.dart';
import '../../model/manga/read_manga_coordinator.dart';
import 'manga_reader_contract.dart';

/// 管理漫画初始化、章节切换、图片位置、历史和加入书架的 MVI ViewModel。
final class MangaReaderViewModel {
  /// 创建页面生命周期独占的漫画 ViewModel。
  MangaReaderViewModel({
    required this.bookUrl,
    this.initialBook,
    this.initialChapterIndex,
    this.initialIsInBookshelf,
    this.initialChapters = const <BookChapter>[],
    this.entry = 'bookshelf',
    required BookshelfGateway bookshelfGateway,
    required ReadingHistoryGateway readingHistoryGateway,
    required LoadBookChaptersUseCase loadBookChapters,
    required SaveReadingProgressUseCase saveReadingProgress,
    required RecordReadingHistoryUseCase recordReadingHistory,
    required AddBookToBookshelfUseCase addBookToBookshelf,
    required ReadMangaCoordinator coordinator,
  }) : _bookshelfGateway = bookshelfGateway,
       _readingHistoryGateway = readingHistoryGateway,
       _loadBookChapters = loadBookChapters,
       _saveReadingProgress = saveReadingProgress,
       _recordReadingHistory = recordReadingHistory,
       _addBookToBookshelf = addBookToBookshelf,
       _coordinator = coordinator {
    /// 只接受主键与图片类型都匹配的入口书籍快照。
    final Book? routeBook = initialBook?.bookUrl == bookUrl &&
            (initialBook?.isImage ?? false)
        ? initialBook
        : null;
    /// 只接受全部归属于当前书籍的目录快照。
    final List<BookChapter> routeChapters = initialChapters.isNotEmpty &&
            initialChapters.every(
              (BookChapter chapter) => chapter.bookUrl == bookUrl,
            )
        ? initialChapters
        : const <BookChapter>[];
    /// 首帧壳使用的非负章节索引。
    final int shellIndex = math.max(
      0,
      initialChapterIndex ?? routeBook?.durChapterIndex ?? 0,
    );
    _state = MangaReaderUiState(
      book: routeBook,
      chapters: routeChapters,
      position: MangaReadingPosition(
        chapterIndex: shellIndex,
        imageIndex: routeBook?.durChapterPos ?? 0,
      ),
      isInBookshelf: initialIsInBookshelf ?? false,
      readerConfig: MangaReaderConfig.fromReadConfig(
        mangaScrollMode: routeBook?.readConfig?.mangaScrollMode,
        webtoonSidePaddingDp: routeBook?.readConfig?.webtoonSidePaddingDp,
      ),
    );
  }

  /// 路由书籍稳定 URL。
  final String bookUrl;

  /// 路由携带的书籍快照。
  final Book? initialBook;

  /// 详情目录明确指定的初始章节。
  final int? initialChapterIndex;

  /// 入口已知的书架成员事实。
  final bool? initialIsInBookshelf;

  /// 入口携带的完整目录快照。
  final List<BookChapter> initialChapters;

  /// 匿名入口枚举，预留给后续漫画阅读埋点。
  final String entry;

  /// 书架书籍读取边界。
  final BookshelfGateway _bookshelfGateway;

  /// 阅读历史书籍、目录和进度边界。
  final ReadingHistoryGateway _readingHistoryGateway;

  /// 持久目录读取 UseCase。
  final LoadBookChaptersUseCase _loadBookChapters;

  /// 把漫画图片索引写入兼容 `durChapterPos` 的 UseCase。
  final SaveReadingProgressUseCase _saveReadingProgress;

  /// 首张图片成功显示后记录阅读历史快照的 UseCase。
  final RecordReadingHistoryUseCase _recordReadingHistory;

  /// 漫画工具栏显式加入书架动作。
  final AddBookToBookshelfUseCase _addBookToBookshelf;

  /// 正文和图片加载协调器。
  final ReadMangaCoordinator _coordinator;

  /// 状态广播控制器。
  final StreamController<MangaReaderUiState> _stateController =
      StreamController<MangaReaderUiState>.broadcast();

  /// 一次性 Effect 广播控制器。
  final StreamController<MangaReaderEffect> _effectController =
      StreamController<MangaReaderEffect>.broadcast();

  /// 当前不可变状态。
  late MangaReaderUiState _state;

  /// 当前章节对应的书源；只保留在 ViewModel，不进入 UiState。
  BookSource? _currentSource;

  /// 当前初始化或切章代次。
  int _loadGeneration = 0;

  /// 可见图片变化后的节流保存定时器。
  Timer? _progressSaveTimer;

  /// 串行化进度写入，保证较旧页面不能在较新页面之后落库。
  Future<void> _progressSaveTail = Future<void>.value();

  /// 是否已经为本次阅读记录历史快照。
  bool _historyRecorded = false;

  /// 是否正在提交首次历史快照，阻止相邻图片同时首显造成重复写入。
  bool _recordingHistory = false;

  /// 用户是否已经在当前路由显式切换过模式，防止晚到书籍快照覆盖选择。
  bool _readingModeChangedByUser = false;

  /// 账号作用域变化后禁止所有旧页面异步结果和持久化写入。
  bool _userScopeInvalidated = false;

  /// 是否已释放页面资源。
  bool _disposed = false;

  /// 当前状态同步快照。
  MangaReaderUiState get state => _state;

  /// 状态变化流。
  Stream<MangaReaderUiState> get states => _stateController.stream;

  /// 一次性 Effect 流。
  Stream<MangaReaderEffect> get effects => _effectController.stream;

  /// 单一意图入口。
  void onIntent(MangaReaderIntent intent) {
    switch (intent) {
      case InitializeMangaReaderIntent():
        unawaited(_initialize());
      case RetryMangaChapterIntent(:final bool forceRefresh):
        unawaited(_retry(forceRefresh: forceRefresh));
      case PreviousMangaChapterIntent():
        unawaited(_moveChapter(-1));
      case NextMangaChapterIntent():
        unawaited(_moveChapter(1));
      case JumpToMangaChapterIntent(:final int chapterIndex):
        unawaited(_jumpToChapter(chapterIndex));
      case MangaVisibleImageChangedIntent(:final int imageIndex):
        _onVisibleImageChanged(imageIndex);
      case ChangeMangaReadingModeIntent(:final MangaReadingMode mode):
        _changeReadingMode(mode);
      case MangaZoomChangedIntent(:final bool isZoomed):
        _changeZoomState(isZoomed);
      case ToggleMangaMenuIntent():
        _emit(_state.copyWith(menuVisible: !_state.menuVisible));
      case AddMangaToBookshelfIntent():
        unawaited(_addToBookshelf());
      case MangaImageDisplayedIntent(:final int imageIndex):
        unawaited(_recordSuccessfulImage(imageIndex));
      case SaveMangaProgressIntent():
        unawaited(saveProgress());
      case MangaMemoryPressureIntent():
        _handleMemoryPressure();
      case OpenMangaSourceLoginIntent():
        unawaited(_openSourceLogin());
      case OpenMangaChangeSourceIntent():
        _openChangeSource();
    }
  }

  /// 初始化书籍和目录，并把仓储异常收敛为受控页面错误。
  Future<void> _initialize() async {
    try {
      await _performInitialize();
    } on Object catch (error) {
      if (!_disposed) {
        _emit(
          _state.copyWith(
            loadState: MangaReaderLoadState.error,
            errorMessage: _safeErrorMessage(error),
          ),
        );
      }
    }
  }

  /// 根据当前失败阶段重试初始化或当前章节，避免目录失败时按钮没有响应。
  Future<void> _retry({required bool forceRefresh}) async {
    if (_state.book == null || _state.chapters.isEmpty) {
      await _initialize();
      return;
    }
    await _loadCurrentChapter(forceRefresh: forceRefresh);
  }

  /// 执行书籍、目录、书架成员事实和初始章节初始化。
  Future<void> _performInitialize() async {
    if (_disposed || _userScopeInvalidated || bookUrl.isEmpty) {
      return;
    }
    /// 只接受主键和图片类型匹配的路由书籍。
    final Book? routeBook = initialBook?.bookUrl == bookUrl &&
            (initialBook?.isImage ?? false)
        ? initialBook
        : null;
    /// 路由明确非书架成员时无需查询；其余入口优先恢复真实书架事实。
    final Book? shelfBook = initialIsInBookshelf == false
        ? null
        : routeBook != null && initialIsInBookshelf == true
            ? routeBook
            : await _bookshelfGateway.getBook(bookUrl);
    /// 只有书架和路由都缺少书籍时才回退阅读历史快照。
    final Book? historyBook = shelfBook == null && routeBook == null
        ? await _readingHistoryGateway.getHistoryBook(bookUrl)
        : null;
    if (_disposed || _userScopeInvalidated) {
      return;
    }
    /// 当前漫画最终使用的书籍事实。
    final Book? book = shelfBook ?? routeBook ?? historyBook;
    if (book == null || !book.isImage) {
      _emit(
        _state.copyWith(
          loadState: MangaReaderLoadState.error,
          errorMessage: book == null ? '漫画书籍不存在或历史已失效' : '当前书籍不是图片类型',
        ),
      );
      return;
    }
    /// 路由提供且归属正确的目录快照。
    final List<BookChapter> routeChapters = initialChapters.isNotEmpty &&
            initialChapters.every(
              (BookChapter chapter) => chapter.bookUrl == bookUrl,
            )
        ? List<BookChapter>.unmodifiable(initialChapters)
        : const <BookChapter>[];
    /// 按入口事实读取的最终目录。
    final List<BookChapter> chapters;
    if (routeChapters.isNotEmpty) {
      chapters = routeChapters;
    } else if (shelfBook != null) {
      final AppResult<List<BookChapter>> result =
          await _loadBookChapters.execute(bookUrl);
      if (result is AppFailure<List<BookChapter>>) {
        _emit(
          _state.copyWith(
            book: book,
            loadState: MangaReaderLoadState.error,
            errorMessage: result.error.message,
          ),
        );
        return;
      }
      chapters = (result as AppSuccess<List<BookChapter>>).value;
    } else {
      chapters = await _readingHistoryGateway.getHistoryChapters(bookUrl);
    }
    if (_disposed || _userScopeInvalidated) {
      return;
    }
    if (chapters.isEmpty) {
      _emit(
        _state.copyWith(
          book: book,
          chapters: chapters,
          loadState: MangaReaderLoadState.error,
          errorMessage: '漫画目录为空，请返回详情刷新目录',
        ),
      );
      return;
    }
    /// 从入口指定章节或书籍持久进度恢复的漫画位置。
    final MangaReadingPosition requestedPosition = initialChapterIndex == null
        ? MangaReadingPosition.fromBook(book)
        : MangaReadingPosition(
            chapterIndex: initialChapterIndex ?? 0,
            imageIndex: 0,
          );
    /// 在访问目录前收敛旧章节索引和负图片索引。
    final MangaReadingPosition chapterSafePosition = requestedPosition.clamp(
      chapterCount: chapters.length,
    );
    /// 收窄并跳过卷标题后的首个可阅读章节。
    final int readableIndex = _nearestReadableIndex(
      chapters,
      chapterSafePosition.chapterIndex,
    );
    _emit(
      _state.copyWith(
        book: book,
        chapters: chapters,
        position: chapterSafePosition.copyWith(
          chapterIndex: readableIndex,
          imageIndex: readableIndex == chapterSafePosition.chapterIndex
              ? chapterSafePosition.imageIndex
              : 0,
        ),
        isInBookshelf: shelfBook != null || initialIsInBookshelf == true,
        loadState: MangaReaderLoadState.loadingChapter,
        clearError: true,
        readerConfig: _readingModeChangedByUser
            ? _state.readerConfig
            : MangaReaderConfig.fromReadConfig(
                mangaScrollMode: book.readConfig?.mangaScrollMode,
                webtoonSidePaddingDp: book.readConfig?.webtoonSidePaddingDp,
              ),
      ),
    );
    await _loadCurrentChapter();
  }

  /// 加载状态中的当前章节，并拒绝旧代次晚到提交。
  Future<void> _loadCurrentChapter({bool forceRefresh = false}) async {
    final Book? book = _state.book;
    if (_disposed ||
        _userScopeInvalidated ||
        book == null ||
        _state.chapters.isEmpty) {
      return;
    }
    /// 当前 ViewModel 加载代次。
    final int generation = ++_loadGeneration;
    _emit(
      _state.copyWith(
        loadState: MangaReaderLoadState.loadingChapter,
        clearCurrentChapter: true,
        clearAdjacentChapters: true,
        clearError: true,
      ),
    );
    try {
      /// 正文解析和书源加载结果。
      final LoadedMangaChapter loaded = await _coordinator.loadChapter(
        book: book,
        chapters: _state.chapters,
        chapterIndex: _state.currentChapterIndex,
        forceRefresh: forceRefresh,
      );
      if (_disposed || _userScopeInvalidated || generation != _loadGeneration) {
        return;
      }
      _currentSource = loaded.source;
      /// 在真实图片数量内收敛旧图片索引，越界时定位最后一张有效图片。
      final MangaReadingPosition safePosition = _state.position.clamp(
        chapterCount: _state.chapters.length,
        imageCount: loaded.chapter.imageCount,
      );
      _emit(
        _state.copyWith(
          currentChapter: loaded.chapter,
          position: safePosition,
          loadState: MangaReaderLoadState.ready,
          clearError: true,
          menuVisible: loaded.chapter.imageCount == 0,
        ),
      );
      _prefetchImages();
      unawaited(_preloadAdjacentChapters(generation, book));
    } on Object catch (error) {
      if (_disposed || _userScopeInvalidated || generation != _loadGeneration) {
        return;
      }
      _emit(
        _state.copyWith(
          loadState: MangaReaderLoadState.error,
          errorMessage: _safeErrorMessage(error),
          menuVisible: true,
        ),
      );
    }
  }

  /// 切换到指定方向的下一条非卷标题目录项。
  Future<void> _moveChapter(int direction) async {
    /// 目标可阅读章节索引。
    final int? target = _readableIndexFrom(_state.currentChapterIndex, direction);
    if (target == null) {
      _effectController.add(
        ShowMangaReaderMessageEffect(direction < 0 ? '已经是第一章' : '已经是最后一章'),
      );
      return;
    }
    await saveProgress();
    _emit(
      _state.copyWith(
        currentChapterIndex: target,
        currentImageIndex: 0,
        clearCurrentChapter: true,
        clearAdjacentChapters: true,
        isZoomed: false,
      ),
    );
    await _loadCurrentChapter();
  }

  /// 从目录跳转指定非卷标题章节。
  Future<void> _jumpToChapter(int chapterIndex) async {
    if (chapterIndex < 0 ||
        chapterIndex >= _state.chapters.length ||
        _state.chapters[chapterIndex].isVolume) {
      _effectController.add(const ShowMangaReaderMessageEffect('请选择可阅读章节'));
      return;
    }
    if (chapterIndex == _state.currentChapterIndex) {
      return;
    }
    await saveProgress();
    _emit(
      _state.copyWith(
        currentChapterIndex: chapterIndex,
        currentImageIndex: 0,
        clearCurrentChapter: true,
        clearAdjacentChapters: true,
        isZoomed: false,
      ),
    );
    await _loadCurrentChapter();
  }

  /// 屏幕中心图片改变后更新领域状态并节流保存。
  void _onVisibleImageChanged(int imageIndex) {
    if (_disposed ||
        imageIndex < 0 ||
        imageIndex >= _state.imageCount ||
        imageIndex == _state.currentImageIndex) {
      return;
    }
    _emit(_state.copyWith(currentImageIndex: imageIndex));
    _prefetchImages();
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(saveProgress()),
    );
  }

  /// 以当前稳定图片索引为锚点切换布局，不修改章节和阅读位置。
  void _changeReadingMode(MangaReadingMode mode) {
    if (_disposed || mode == _state.readerConfig.readingMode) {
      return;
    }
    _readingModeChangedByUser = true;
    _emit(
      _state.copyWith(
        readerConfig: _state.readerConfig.copyWith(readingMode: mode),
        isZoomed: false,
      ),
    );
  }

  /// 同步当前图片缩放状态，供分页容器解决手势竞争。
  void _changeZoomState(bool isZoomed) {
    if (_disposed || isZoomed == _state.isZoomed) {
      return;
    }
    _emit(_state.copyWith(isZoomed: isZoomed));
  }

  /// 当前章成功后加载有界相邻章清单，再启动最低优先级的图片文件预取。
  Future<void> _preloadAdjacentChapters(int generation, Book book) async {
    final MangaAdjacentChapterWindow window =
        await _coordinator.preloadAdjacentChapters(
          book: book,
          chapters: _state.chapters,
          currentIndex: _state.currentChapterIndex,
        );
    if (_disposed ||
        _userScopeInvalidated ||
        generation != _loadGeneration ||
        _state.currentChapter == null) {
      return;
    }
    _emit(
      _state.copyWith(
        previousChapter: window.previous,
        nextChapter: window.next,
      ),
    );
    _prefetchImages();
  }

  /// 按当前图片附近优先顺序启动有界磁盘预取，不等待也不污染页面错误。
  void _prefetchImages() {
    final Book? book = _state.book;
    final BookSource? source = _currentSource;
    final MangaChapter? current = _state.currentChapter;
    if (_disposed ||
        _userScopeInvalidated ||
        book == null ||
        source == null ||
        current == null ||
        current.pages.isEmpty) {
      return;
    }
    unawaited(
      _coordinator.prefetchImages(
        book: book,
        source: source,
        current: current,
        currentImageIndex: _state.currentImageIndex,
        previous: _state.previousChapter,
        next: _state.nextChapter,
      ),
    );
  }

  /// 内存压力时保留当前章节和稳定位置，只丢弃相邻章窗口及低优先级任务。
  void _handleMemoryPressure() {
    _coordinator.handleMemoryPressure();
    _emit(
      _state.copyWith(
        clearAdjacentChapters: true,
        isZoomed: false,
      ),
    );
    unawaited(saveProgress());
  }

  /// 解析当前书源的登录地址，并把实际 WebView 导航交给 Route。
  Future<void> _openSourceLogin() async {
    final Book? book = _state.book;
    if (_disposed || _userScopeInvalidated || book == null) {
      return;
    }
    try {
      /// 章节正文失败前可能尚未提交书源，因此按书籍来源补查一次。
      final BookSource? source =
          _currentSource ?? await _coordinator.sourceForBook(book);
      if (_disposed || _userScopeInvalidated) {
        return;
      }
      if (source == null) {
        _effectController.add(const ShowMangaReaderMessageEffect('原书源已不存在'));
        return;
      }
      _currentSource = source;
      /// 书源登录地址为空时回退书源主页，与现有书源管理行为保持一致。
      final String configuredLoginUrl = source.loginUrl?.trim() ?? '';
      /// 交给 Route 校验并打开的登录目标。
      final String targetUrl = configuredLoginUrl.isNotEmpty
          ? configuredLoginUrl
          : source.bookSourceUrl.trim();
      if (targetUrl.isEmpty) {
        _effectController.add(const ShowMangaReaderMessageEffect('当前书源未配置登录地址'));
        return;
      }
      _effectController.add(
        OpenMangaSourceLoginEffect(
          sourceUrl: targetUrl,
          title: source.bookSourceName,
        ),
      );
    } on Object {
      if (!_disposed && !_userScopeInvalidated) {
        _effectController.add(const ShowMangaReaderMessageEffect('读取书源登录信息失败'));
      }
    }
  }

  /// 校验书架成员事实后请求打开整书换源页面。
  void _openChangeSource() {
    final Book? book = _state.book;
    if (_disposed || _userScopeInvalidated || book == null) {
      return;
    }
    if (!_state.isInBookshelf) {
      _effectController.add(const ShowMangaReaderMessageEffect('请先将漫画加入书架再整书换源'));
      return;
    }
    _effectController.add(OpenMangaChangeSourceEffect(book.bookUrl));
  }

  /// 整书换源成功并准备替换路由时，取消旧主键任务且禁止销毁阶段再次落库。
  void prepareForRouteReplacement() {
    if (_disposed || _userScopeInvalidated) {
      return;
    }
    _userScopeInvalidated = true;
    _loadGeneration += 1;
    _progressSaveTimer?.cancel();
    _coordinator.dispose();
  }

  /// 图片 Cell 通过 ViewModel 取得受控本地文件，不接触书源 Header。
  Future<MangaImageResource> resolveImage(
    MangaPage page, {
    required HttpCancellationToken cancellationToken,
    MangaImageProgress? onProgress,
    required bool forceRefresh,
  }) {
    final Book? book = _state.book;
    final BookSource? source = _currentSource;
    if (_userScopeInvalidated) {
      throw const MangaImageException(
        MangaImageFailureKind.cancelled,
        '账号已切换，漫画图片请求已取消',
      );
    }
    if (book == null || source == null) {
      throw const MangaImageException(
        MangaImageFailureKind.invalidRequest,
        '漫画书籍或书源尚未准备完成',
      );
    }
    return _coordinator.resolveImage(
      book: book,
      source: source,
      page: page,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
      forceRefresh: forceRefresh,
    );
  }

  /// 创建图片 Cell 生命周期取消令牌。
  HttpCancellationToken createImageCancellationToken() {
    return _coordinator.createImageCancellationToken();
  }

  /// 首张图片真实显示后记录历史快照，加载失败不伪装成成功阅读。
  Future<void> _recordSuccessfulImage(int imageIndex) async {
    if (_disposed ||
        _userScopeInvalidated ||
        _historyRecorded ||
        _recordingHistory ||
        imageIndex < 0) {
      return;
    }
    final Book? book = _state.book;
    final MangaChapter? chapter = _state.currentChapter;
    if (book == null || chapter == null || _state.chapters.isEmpty) {
      return;
    }
    /// 记录首显图片位置的当前时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 携带漫画图片索引的历史书籍快照。
    final Book historyBook = book.copyWithProgress(
      chapterIndex: _state.currentChapterIndex,
      chapterPos: imageIndex,
      readTime: now,
      chapterTitle: chapter.chapter.title,
    );
    _recordingHistory = true;
    try {
      final AppResult<void> result = await _recordReadingHistory.execute(
        historyBook,
        _state.chapters,
      );
      if (_disposed || _userScopeInvalidated) {
        return;
      }
      if (result is AppFailure<void>) {
        _effectController.add(
          const ShowMangaReaderMessageEffect('漫画已打开，但历史记录保存失败'),
        );
        return;
      }
      _historyRecorded = true;
      _emit(_state.copyWith(book: historyBook, currentImageIndex: imageIndex));
    } finally {
      _recordingHistory = false;
    }
  }

  /// 显式加入当前漫画到书架；同名冲突留给完整冲突面板处理。
  Future<void> _addToBookshelf() async {
    if (_userScopeInvalidated ||
        _state.isInBookshelf ||
        _state.addingToBookshelf) {
      return;
    }
    final Book? book = _state.book;
    if (book == null || _state.chapters.isEmpty) {
      _effectController.add(const ShowMangaReaderMessageEffect('漫画或目录尚未准备完成'));
      return;
    }
    _emit(_state.copyWith(addingToBookshelf: true));
    /// 使用当前图片位置写入的新书架书籍。
    final Book shelfBook = book.copyWithProgress(
      chapterIndex: _state.currentChapterIndex,
      chapterPos: _state.currentImageIndex,
      readTime: DateTime.now().millisecondsSinceEpoch,
      chapterTitle: _state.currentChapter?.chapter.title,
    );
    final AppResult<AddBookToBookshelfResult> result =
        await _addBookToBookshelf.execute(shelfBook, _state.chapters);
    if (_disposed || _userScopeInvalidated) {
      return;
    }
    switch (result) {
      case AppFailure<AddBookToBookshelfResult>(error: final error):
        _emit(_state.copyWith(addingToBookshelf: false));
        _effectController.add(ShowMangaReaderMessageEffect(error.message));
      case AppSuccess<AddBookToBookshelfResult>(value: final value):
        switch (value) {
          case BookAddedToBookshelf(book: final Book addedBook):
            _emit(
              _state.copyWith(
                book: addedBook,
                isInBookshelf: true,
                addingToBookshelf: false,
              ),
            );
            _effectController.add(const ShowMangaReaderMessageEffect('已加入书架'));
          case BookAlreadyInBookshelf():
            _emit(
              _state.copyWith(
                isInBookshelf: true,
                addingToBookshelf: false,
              ),
            );
            _effectController.add(const ShowMangaReaderMessageEffect('该漫画已在书架中'));
          case BookShelfConflict():
            _emit(_state.copyWith(addingToBookshelf: false));
            _effectController.add(
              const ShowMangaReaderMessageEffect('书架存在同名漫画，请从详情页选择覆盖或再次添加'),
            );
        }
    }
  }

  /// 立即保存当前章节和图片索引到书架兼容进度与阅读历史。
  Future<void> saveProgress() {
    _progressSaveTimer?.cancel();
    if (_userScopeInvalidated) {
      return Future<void>.value();
    }
    final Book? book = _state.book;
    final MangaChapter? chapter = _state.currentChapter;
    if (book == null || chapter == null) {
      return Future<void>.value();
    }
    /// 当前进度保存时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 将漫画图片语义只在持久化边界映射到兼容 `chapterPos` 字段。
    final MangaReadingPosition position = _state.position.clamp(
      chapterCount: _state.chapters.length,
      imageCount: chapter.imageCount,
    );
    /// 排在所有更早进度写入之后的本次保存任务。
    final Future<void> operation = _progressSaveTail.then((_) {
      return _persistProgress(
        book: book,
        chapter: chapter,
        position: position,
        readTime: now,
      );
    });
    _progressSaveTail = operation;
    return operation;
  }

  /// 将一个调用时冻结的漫画位置依次写入书架和同作用域阅读历史。
  Future<void> _persistProgress({
    required Book book,
    required MangaChapter chapter,
    required MangaReadingPosition position,
    required int readTime,
  }) async {
    if (_userScopeInvalidated) {
      return;
    }
    await _saveReadingProgress.execute(
      position.toReadingProgress(
        bookUrl: book.bookUrl,
        readTime: readTime,
        chapterTitle: chapter.chapter.title,
        syncTime: book.syncTime,
      ),
    );
    if (_userScopeInvalidated) {
      return;
    }
    try {
      await _readingHistoryGateway.updateHistoryProgress(
        bookUrl: book.bookUrl,
        chapterIndex: position.chapterIndex,
        chapterPos: position.imageIndex,
        readTime: readTime,
        chapterTitle: chapter.chapter.title,
      );
    } on Object {
      // 书架和历史是独立事实；历史更新失败不回滚已经完成的书架进度。
    }
    if (!_disposed) {
      _emit(
        _state.copyWith(
          book: book.copyWithProgress(
            chapterIndex: position.chapterIndex,
            chapterPos: position.imageIndex,
            readTime: readTime,
            chapterTitle: chapter.chapter.title,
          ),
        ),
      );
    }
  }

  /// 从当前章节向指定方向查找非卷标题目录项。
  int? _readableIndexFrom(int currentIndex, int direction) {
    int index = currentIndex + direction;
    while (index >= 0 && index < _state.chapters.length) {
      if (!_state.chapters[index].isVolume) {
        return index;
      }
      index += direction;
    }
    return null;
  }

  /// 初始索引是卷标题时优先向后、再向前寻找可阅读章节。
  static int _nearestReadableIndex(List<BookChapter> chapters, int requestedIndex) {
    if (!chapters[requestedIndex].isVolume) {
      return requestedIndex;
    }
    for (int index = requestedIndex + 1; index < chapters.length; index += 1) {
      if (!chapters[index].isVolume) {
        return index;
      }
    }
    for (int index = requestedIndex - 1; index >= 0; index -= 1) {
      if (!chapters[index].isVolume) {
        return index;
      }
    }
    return requestedIndex;
  }

  /// 将底层异常收敛为不包含 URL、Header 和本地路径的用户提示。
  static String _safeErrorMessage(Object error) {
    return switch (error) {
      ReadMangaException(:final String message) => message,
      MangaImageException(:final String message) => message,
      UnifiedHttpException(:final String message) => message,
      StandardRuleException(:final String message) => message,
      JsEngineException(:final String message) => message,
      _ => '漫画章节加载失败，请重试或更换书源',
    };
  }

  /// 提交新状态。
  void _emit(MangaReaderUiState value) {
    if (_disposed) {
      return;
    }
    _state = value;
    _stateController.add(value);
  }

  /// 账号切换时立即封存旧作用域页面，取消网络和定时写入且不向新账号保存旧进度。
  void invalidateForUserScopeChange() {
    if (_disposed || _userScopeInvalidated) {
      return;
    }
    _userScopeInvalidated = true;
    _loadGeneration += 1;
    _progressSaveTimer?.cancel();
    _coordinator.dispose();
  }

  /// 释放请求、定时器和流；退出前提交一次当前进度。
  void dispose() {
    if (_disposed) {
      return;
    }
    if (!_userScopeInvalidated) {
      unawaited(saveProgress());
    }
    _disposed = true;
    _progressSaveTimer?.cancel();
    _coordinator.dispose();
    unawaited(_stateController.close());
    unawaited(_effectController.close());
  }
}
