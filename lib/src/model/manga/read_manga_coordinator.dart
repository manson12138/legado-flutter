import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/gateway/manga_image_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/manga_chapter.dart';
import '../../domain/model/manga_page.dart';
import '../web_book/standard_source_parser.dart';
import '../web_book/standard_source_service.dart';
import 'manga_content_parser.dart';

/// 漫画章节加载成功后交给 ViewModel 的章节和书源事实。
final class LoadedMangaChapter {
  /// 创建不可变加载结果。
  const LoadedMangaChapter({required this.chapter, required this.source});

  /// 已完成图片地址解析的漫画章节。
  final MangaChapter chapter;

  /// 当前书籍使用的网络书源，图片请求继续复用其 Header 和 Cookie 策略。
  final BookSource source;
}

/// 当前章成功后有界预取出的上一章和下一章图片清单。
final class MangaAdjacentChapterWindow {
  /// 创建不可变相邻章窗口；任一方向缺失或失败时保持为空。
  const MangaAdjacentChapterWindow({this.previous, this.next});

  /// 最近的上一可阅读章节。
  final MangaChapter? previous;

  /// 最近的下一可阅读章节。
  final MangaChapter? next;
}

/// 漫画正文加载、原始正文缓存、图片解析和图片仓储协调器，对应 Android `ReadManga`。
final class ReadMangaCoordinator {
  /// 创建页面生命周期独占的漫画协调器。
  ReadMangaCoordinator({
    required BookSourceGateway sourceGateway,
    required ReaderCacheGateway cacheGateway,
    required StandardBookSourceService standardService,
    required MangaImageGateway imageGateway,
    required MangaContentParser contentParser,
    required HttpCancellationToken Function() cancellationTokenFactory,
  }) : _sourceGateway = sourceGateway,
       _cacheGateway = cacheGateway,
       _standardService = standardService,
       _imageGateway = imageGateway,
       _contentParser = contentParser,
       _cancellationTokenFactory = cancellationTokenFactory;

  /// 当前书籍的书源读取和质量结果边界。
  final BookSourceGateway _sourceGateway;

  /// 与文本阅读器共用的七天原始章节正文缓存。
  final ReaderCacheGateway _cacheGateway;

  /// 普通规则和 JavaScript 混合正文请求入口。
  final StandardBookSourceService _standardService;

  /// 图片网络获取和应用私有文件缓存边界。
  final MangaImageGateway _imageGateway;

  /// 安全章节图片解析器。
  final MangaContentParser _contentParser;

  /// 创建当前章节或图片请求取消令牌的工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 当前前台章节请求令牌；切章和销毁时立即取消。
  HttpCancellationToken? _chapterToken;

  /// 当前章节请求代次，阻止取消后晚到的旧结果覆盖新章节。
  int _chapterGeneration = 0;

  /// 只保留上一章、当前章和下一章的解析结果，键为目录索引。
  final Map<int, LoadedMangaChapter> _chapterWindow =
      <int, LoadedMangaChapter>{};

  /// 相邻章节正文清单预取令牌。
  final List<HttpCancellationToken> _chapterPreloadTokens =
      <HttpCancellationToken>[];

  /// 相邻章节正文预取代次。
  int _chapterPreloadGeneration = 0;

  /// 当前页附近和相邻章图片文件预取令牌。
  final List<HttpCancellationToken> _imagePrefetchTokens =
      <HttpCancellationToken>[];

  /// 图片文件预取代次。
  int _imagePrefetchGeneration = 0;

  /// 读取当前书籍使用的书源，供章节失败后打开登录恢复入口。
  Future<BookSource?> sourceForBook(Book book) {
    return _sourceGateway.getByUrl(book.origin);
  }

  /// 加载目标漫画章节；强制刷新会同时失效原始正文缓存。
  Future<LoadedMangaChapter> loadChapter({
    required Book book,
    required List<BookChapter> chapters,
    required int chapterIndex,
    bool forceRefresh = false,
  }) async {
    if (chapterIndex < 0 || chapterIndex >= chapters.length) {
      throw const ReadMangaException('目标章节不存在');
    }
    _chapterToken?.cancel('漫画切换章节');
    _cancelChapterPreloads('当前章节请求优先');
    _cancelImagePrefetches('当前章节请求优先');
    /// 当前请求独占的取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _chapterToken = token;
    /// 当前章节加载代次。
    final int generation = ++_chapterGeneration;
    try {
      /// 强制刷新不能复用窗口，否则优先复用相邻章已经完成的解析结果。
      final LoadedMangaChapter? cached = forceRefresh
          ? null
          : _chapterWindow[chapterIndex];
      final LoadedMangaChapter loaded = cached ??
          await _loadChapterCore(
            book: book,
            chapters: chapters,
            chapterIndex: chapterIndex,
            token: token,
            forceRefresh: forceRefresh,
          );
      if (token.isCancelled || generation != _chapterGeneration) {
        throw const ReadMangaException('章节请求已取消');
      }
      _chapterWindow[chapterIndex] = loaded;
      _trimChapterWindow(chapters: chapters, currentIndex: chapterIndex);
      return loaded;
    } finally {
      if (identical(_chapterToken, token)) {
        _chapterToken = null;
      }
    }
  }

  /// 完成一个章节的正文缓存、网络请求和图片清单解析，不改变可见章状态。
  Future<LoadedMangaChapter> _loadChapterCore({
    required Book book,
    required List<BookChapter> chapters,
    required int chapterIndex,
    required HttpCancellationToken token,
    bool forceRefresh = false,
    bool recordSourceOutcome = true,
  }) async {
    /// 目标目录章节。
    final BookChapter chapter = chapters[chapterIndex];
    /// 当前书籍对应的网络书源。
    final BookSource? source = await _sourceGateway.getByUrl(book.origin);
    if (source == null) {
      throw const ReadMangaException('原书源已不存在');
    }
    if (chapter.isVolume) {
      return LoadedMangaChapter(
        chapter: _contentParser.parse(
          chapter: chapter,
          chapterCount: chapters.length,
          content: '',
        ),
        source: source,
      );
    }
    if (forceRefresh) {
      await _cacheGateway.removeChapterContent(book.bookUrl, chapter.url);
    }
    /// 优先读取与文本阅读器共用的原始正文缓存。
    String? content = forceRefresh
        ? null
        : await _cacheGateway.getChapterContent(
            book.bookUrl,
            chapter.url,
            DateTime.now().millisecondsSinceEpoch,
          );
    /// 当前请求是否真实访问了网络书源。
    bool requestedNetwork = false;
    if (content == null) {
      requestedNetwork = true;
      try {
        /// 下一目录章节地址，供正文规则处理章节边界。
        final String? nextChapterUrl = chapterIndex + 1 < chapters.length
            ? chapters[chapterIndex + 1].url
            : null;
        /// 普通规则或 JavaScript 混合正文结果。
        final ParsedContentPage parsed = await _standardService.loadContent(
          source: source,
          book: book,
          chapter: chapter,
          nextChapterUrl: nextChapterUrl,
          cancellationToken: token,
        );
        content = parsed.content;
      } on Object {
        if (!token.isCancelled && recordSourceOutcome) {
          await _recordSourceOutcome(source, delta: -1);
        }
        rethrow;
      }
    }
    if (token.isCancelled) {
      throw const ReadMangaException('章节请求已取消');
    }
    /// 已收窄为非空局部变量的章节正文。
    final String safeContent = content ?? '';
    if (requestedNetwork && safeContent.isNotEmpty) {
      await _cacheGateway.saveChapterContent(
        book.bookUrl,
        chapter.url,
        safeContent,
        DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch,
      );
      if (recordSourceOutcome) {
        await _recordSourceOutcome(source, delta: 1);
      }
    }
    /// 从安全标记或 HTML 中恢复的有序漫画章节。
    final MangaChapter mangaChapter = _contentParser.parse(
      chapter: chapter,
      chapterCount: chapters.length,
      content: safeContent,
    );
    return LoadedMangaChapter(chapter: mangaChapter, source: source);
  }

  /// 当前章成功后只预取最近上一章和下一章的图片清单，失败不会抛给当前阅读状态。
  Future<MangaAdjacentChapterWindow> preloadAdjacentChapters({
    required Book book,
    required List<BookChapter> chapters,
    required int currentIndex,
  }) async {
    _cancelChapterPreloads('开始新的相邻章节预取');
    /// 本轮相邻章预取代次。
    final int generation = _chapterPreloadGeneration;
    /// 最近的上一可阅读章节索引。
    final int? previousIndex = _readableIndex(
      chapters: chapters,
      currentIndex: currentIndex,
      direction: -1,
    );
    /// 最近的下一可阅读章节索引。
    final int? nextIndex = _readableIndex(
      chapters: chapters,
      currentIndex: currentIndex,
      direction: 1,
    );
    /// Android 对齐的两个相邻候选，最多固定两个 worker。
    final List<int> candidates = <int>[
      if (nextIndex != null) nextIndex,
      if (previousIndex != null) previousIndex,
    ];
    /// 本轮成功完成的章节清单。
    final Map<int, LoadedMangaChapter> loaded = <int, LoadedMangaChapter>{};
    /// 下一个由 worker 独占领取的候选位置。
    int nextCandidate = 0;

    /// 相邻章节正文固定 worker。
    Future<void> worker() async {
      while (generation == _chapterPreloadGeneration &&
          nextCandidate < candidates.length) {
        /// 当前 worker 领取的候选位置。
        final int candidatePosition = nextCandidate;
        nextCandidate += 1;
        /// 当前预取的目录索引。
        final int chapterIndex = candidates[candidatePosition];
        final LoadedMangaChapter? cached = _chapterWindow[chapterIndex];
        if (cached != null) {
          loaded[chapterIndex] = cached;
          continue;
        }
        /// 当前相邻章请求的取消令牌。
        final HttpCancellationToken token = _cancellationTokenFactory();
        _chapterPreloadTokens.add(token);
        try {
          final LoadedMangaChapter value = await _loadChapterCore(
            book: book,
            chapters: chapters,
            chapterIndex: chapterIndex,
            token: token,
            recordSourceOutcome: false,
          );
          if (!token.isCancelled && generation == _chapterPreloadGeneration) {
            loaded[chapterIndex] = value;
            _chapterWindow[chapterIndex] = value;
          }
        } on Object {
          // 相邻章清单预取是低优先级优化，失败不能覆盖当前章节成功状态。
        } finally {
          _chapterPreloadTokens.remove(token);
        }
      }
    }

    /// 相邻章数量最多为二，因此 worker 上限固定为二。
    final int workerCount = candidates.length.clamp(0, 2).toInt();
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (int _) => worker()),
    );
    if (generation != _chapterPreloadGeneration) {
      return const MangaAdjacentChapterWindow();
    }
    _trimChapterWindow(chapters: chapters, currentIndex: currentIndex);
    return MangaAdjacentChapterWindow(
      previous: previousIndex == null ? null : loaded[previousIndex]?.chapter,
      next: nextIndex == null ? null : loaded[nextIndex]?.chapter,
    );
  }

  /// 按当前页邻近图片优先、相邻章节最低的顺序用两个 worker 预取磁盘文件。
  Future<void> prefetchImages({
    required Book book,
    required BookSource source,
    required MangaChapter current,
    required int currentImageIndex,
    MangaChapter? previous,
    MangaChapter? next,
  }) async {
    _cancelImagePrefetches('当前图片位置变化');
    /// 本轮图片文件预取代次。
    final int generation = _imagePrefetchGeneration;
    /// 当前章节范围内的安全图片索引。
    final int safeIndex = current.imageCount == 0
        ? 0
        : currentImageIndex.clamp(0, current.imageCount - 1).toInt();
    /// 从当前页附近到相邻章边缘页的有界候选队列。
    final List<MangaPage> candidates = <MangaPage>[];
    final Set<String> seenKeys = <String>{};

    /// 按优先级加入一个未重复且有效的图片页。
    void addPage(MangaPage? page) {
      if (page != null && seenKeys.add(page.stableKey)) {
        candidates.add(page);
      }
    }

    for (final int offset in <int>[1, -1, 2, -2]) {
      /// 当前页附近候选索引。
      final int index = safeIndex + offset;
      addPage(index >= 0 && index < current.pages.length
          ? current.pages[index]
          : null);
    }
    addPage(next?.pages.isNotEmpty == true ? next?.pages.first : null);
    addPage(previous?.pages.isNotEmpty == true ? previous?.pages.last : null);
    if (candidates.isEmpty) {
      return;
    }
    /// 给当前可见图片请求一个先进入统一仓储的短暂优先窗口。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (generation != _imagePrefetchGeneration) {
      return;
    }
    /// 下一个由图片 worker 领取的候选位置。
    int nextCandidate = 0;

    /// 固定图片文件预取 worker，单图失败后继续下一候选。
    Future<void> worker() async {
      while (generation == _imagePrefetchGeneration &&
          nextCandidate < candidates.length) {
        /// 当前 worker 独占领取的位置。
        final int candidatePosition = nextCandidate;
        nextCandidate += 1;
        /// 当前待缓存的图片页。
        final MangaPage page = candidates[candidatePosition];
        /// 当前图片预取取消令牌。
        final HttpCancellationToken token = _cancellationTokenFactory();
        _imagePrefetchTokens.add(token);
        try {
          await _imageGateway.resolve(
            book: book,
            source: source,
            page: page,
            cancellationToken: token,
          );
        } on Object {
          // 图片文件预取失败不改变当前图片或章节加载状态。
        } finally {
          _imagePrefetchTokens.remove(token);
        }
      }
    }

    /// 图片下载并发固定为二，最坏同时响应内存受单图 40 MiB 上限约束。
    final int workerCount = candidates.length.clamp(0, 2).toInt();
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (int _) => worker()),
    );
  }

  /// 在目录中查找指定方向最近的非卷标题章节。
  static int? _readableIndex({
    required List<BookChapter> chapters,
    required int currentIndex,
    required int direction,
  }) {
    int index = currentIndex + direction;
    while (index >= 0 && index < chapters.length) {
      if (!chapters[index].isVolume) {
        return index;
      }
      index += direction;
    }
    return null;
  }

  /// 把解析结果窗口裁剪到当前章节前后一章，禁止随阅读无限增长。
  void _trimChapterWindow({
    required List<BookChapter> chapters,
    required int currentIndex,
  }) {
    /// 跳过卷标题后的上一可阅读章节索引。
    final int? previousIndex = _readableIndex(
      chapters: chapters,
      currentIndex: currentIndex,
      direction: -1,
    );
    /// 跳过卷标题后的下一可阅读章节索引。
    final int? nextIndex = _readableIndex(
      chapters: chapters,
      currentIndex: currentIndex,
      direction: 1,
    );
    /// 当前章以及跳过卷标题后的最近前后章索引。
    final Set<int> retainedIndices = <int>{
      currentIndex,
      if (previousIndex != null) previousIndex,
      if (nextIndex != null) nextIndex,
    };
    _chapterWindow.removeWhere(
      (int index, LoadedMangaChapter _) => !retainedIndices.contains(index),
    );
  }

  /// 取消相邻章节正文清单预取并使旧 worker 停止领取任务。
  void _cancelChapterPreloads(String reason) {
    _chapterPreloadGeneration += 1;
    for (final HttpCancellationToken token
        in List<HttpCancellationToken>.of(_chapterPreloadTokens)) {
      token.cancel(reason);
    }
    _chapterPreloadTokens.clear();
  }

  /// 取消图片文件预取并使旧 worker 停止领取任务。
  void _cancelImagePrefetches(String reason) {
    _imagePrefetchGeneration += 1;
    for (final HttpCancellationToken token
        in List<HttpCancellationToken>.of(_imagePrefetchTokens)) {
      token.cancel(reason);
    }
    _imagePrefetchTokens.clear();
  }

  /// 内存压力时取消所有非关键预取并丢弃相邻章解析窗口，当前章由 UiState 保留。
  void handleMemoryPressure() {
    _cancelChapterPreloads('系统内存压力');
    _cancelImagePrefetches('系统内存压力');
    _chapterWindow.clear();
  }

  /// 通过统一图片仓储惰性取得单张图片文件。
  Future<MangaImageResource> resolveImage({
    required Book book,
    required BookSource source,
    required MangaPage page,
    required HttpCancellationToken cancellationToken,
    MangaImageProgress? onProgress,
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) {
      await _imageGateway.invalidate(book: book, page: page);
    }
    return _imageGateway.resolve(
      book: book,
      source: source,
      page: page,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  /// 创建图片 Cell 生命周期独占的取消令牌。
  HttpCancellationToken createImageCancellationToken() {
    return _cancellationTokenFactory();
  }

  /// 记录正文请求最终结果；统计失败不能改变漫画主流程。
  Future<void> _recordSourceOutcome(BookSource source, {required int delta}) async {
    try {
      await _sourceGateway.recordSourceOutcome(
        source.bookSourceUrl,
        delta: delta,
        eventType: 'content',
      );
    } on Object {
      // 质量统计是旁路副作用，不覆盖正文加载的真实成功或失败。
    }
  }

  /// 取消当前章节请求并阻止旧代次继续提交。
  void dispose() {
    _chapterGeneration += 1;
    _chapterToken?.cancel('漫画阅读页面销毁');
    _chapterToken = null;
    _cancelChapterPreloads('漫画阅读页面销毁');
    _cancelImagePrefetches('漫画阅读页面销毁');
    _chapterWindow.clear();
  }
}

/// 漫画章节协调器向 ViewModel 暴露的安全错误。
final class ReadMangaException implements Exception {
  /// 创建不包含 URL、Header 或正文的漫画错误。
  const ReadMangaException(this.message);

  /// 可直接展示的安全错误说明。
  final String message;

  @override
  String toString() => 'ReadMangaException($message)';
}
