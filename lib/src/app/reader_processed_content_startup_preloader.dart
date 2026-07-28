import '../domain/gateway/reader_cache_gateway.dart';
import '../domain/gateway/reading_history_gateway.dart';
import '../domain/gateway/replace_rule_gateway.dart';
import '../domain/model/book.dart';
import '../domain/model/book_chapter.dart';
import '../domain/model/reader_content.dart';
import '../domain/model/replace_rule.dart';
import '../model/reader/reader_processed_content_cache.dart';
import '../model/reader/reader_text_processor.dart';
import 'bookshelf_history_startup_preloader.dart';
import 'current_user_scope.dart';

/// 在主界面首帧后仅使用本地原始正文缓存预热最近阅读书籍的当前章。
///
/// 本服务不依赖书源、HTTP 客户端或本地书解析器，因此原始正文缓存未命中时只能结束，
/// 不会退回网络或文件解析。成功结果写入阅读器共用的有界处理后正文 LRU。
final class ReaderProcessedContentStartupPreloader {
  /// 创建缓存限定的低优先级正文预热器。
  ReaderProcessedContentStartupPreloader({
    required BookshelfHistoryStartupPreloader startupSnapshotPreloader,
    required ReadingHistoryGateway readingHistoryGateway,
    required ReaderCacheGateway cacheGateway,
    required ReplaceRuleGateway replaceRuleGateway,
    required ReaderTextProcessor textProcessor,
    required ReaderProcessedContentCache processedContentCache,
    required CurrentUserScope currentUserScope,
  }) : _startupSnapshotPreloader = startupSnapshotPreloader,
       _readingHistoryGateway = readingHistoryGateway,
       _cacheGateway = cacheGateway,
       _replaceRuleGateway = replaceRuleGateway,
       _textProcessor = textProcessor,
       _processedContentCache = processedContentCache,
       _currentUserScope = currentUserScope;

  /// 已有书架与阅读历史本地首快照。
  final BookshelfHistoryStartupPreloader _startupSnapshotPreloader;

  /// 读取最近阅读书籍保存的本地目录快照。
  final ReadingHistoryGateway _readingHistoryGateway;

  /// 只读原始正文持久缓存和同步显示配置快照。
  final ReaderCacheGateway _cacheGateway;

  /// 读取当前书籍适用的本地正文替换规则。
  final ReplaceRuleGateway _replaceRuleGateway;

  /// 在独立 isolate 完成正文净化、替换和分块。
  final ReaderTextProcessor _textProcessor;

  /// 阅读页面与启动预热共用的应用级有界正文 LRU。
  final ReaderProcessedContentCache _processedContentCache;

  /// 用于隔离游客、账号及切换前晚到结果的当前用户作用域。
  final CurrentUserScope _currentUserScope;

  /// 当前作用域唯一的预热任务。
  Future<void>? _preloadFuture;

  /// 当前正文处理任务的取消令牌，不会写入处理后正文缓存。
  ReaderTextProcessCancellationToken? _activeProcessingToken;

  /// 每次取消时递增，阻止 SQLite 或 isolate 的晚到结果写回 LRU。
  int _taskGeneration = 0;

  /// 当前用户作用域是否仍允许启动期预热。
  bool _preloadAllowed = true;

  /// 启动或复用当前用户作用域唯一的缓存限定预热任务。
  Future<void> preload() {
    if (!_preloadAllowed) {
      return Future<void>.value();
    }
    final Future<void>? existing = _preloadFuture;
    if (existing != null) {
      return existing;
    }
    final int userId = _currentUserScope.requireUserId();
    final int userGeneration = _currentUserScope.generation;
    final int taskGeneration = _taskGeneration;
    final ReaderTextProcessCancellationToken processingToken =
        ReaderTextProcessCancellationToken();
    _activeProcessingToken = processingToken;
    final Future<void> future = _preload(
      userId: userId,
      userGeneration: userGeneration,
      taskGeneration: taskGeneration,
      processingToken: processingToken,
    );
    _preloadFuture = future;
    return future;
  }

  /// 当前可见阅读任务开始后永久关闭本作用域的启动预热并立即释放处理 isolate。
  void cancelForForegroundReader() {
    _preloadAllowed = false;
    _cancelActiveTask();
  }

  /// 系统内存压力下关闭非关键预热；已有 LRU 由应用根部统一清理。
  void handleMemoryPressure() {
    _preloadAllowed = false;
    _cancelActiveTask();
  }

  /// 账号或游客作用域变化时取消旧任务，并允许新作用域重新预热一次。
  void invalidateUserSession() {
    _cancelActiveTask();
    _preloadFuture = null;
    _preloadAllowed = true;
  }

  /// 应用销毁时取消仍在运行的低优先级任务。
  void dispose() {
    _preloadAllowed = false;
    _cancelActiveTask();
    _preloadFuture = null;
  }

  /// 执行最近一本书当前章的本地缓存读取与后台正文处理。
  Future<void> _preload({
    required int userId,
    required int userGeneration,
    required int taskGeneration,
    required ReaderTextProcessCancellationToken processingToken,
  }) async {
    ReaderProcessedContentCacheToken? cacheToken;
    try {
      final BookshelfHistoryStartupSnapshot snapshot =
          await _startupSnapshotPreloader.preload();
      if (!_isCurrent(
            userId: userId,
            userGeneration: userGeneration,
            taskGeneration: taskGeneration,
            processingToken: processingToken,
          ) ||
          snapshot.userId != userId ||
          snapshot.readingHistoryBooks.isEmpty) {
        return;
      }
      /// 阅读历史 DAO 已按最近阅读时间倒序返回，首项即唯一预热候选。
      final Book book = snapshot.readingHistoryBooks.first;
      if (book.origin == 'loc_book' &&
          book.originName.toLowerCase().endsWith('.pdf')) {
        return;
      }
      final List<BookChapter> chapters =
          await _readingHistoryGateway.getHistoryChapters(book.bookUrl);
      if (!_isCurrent(
            userId: userId,
            userGeneration: userGeneration,
            taskGeneration: taskGeneration,
            processingToken: processingToken,
          )) {
        return;
      }
      final BookChapter? chapter = _resolveReadableChapter(book, chapters);
      if (chapter == null) {
        return;
      }
      /// 这是启动预热唯一允许的正文来源；未命中时不得调用前台正文协调器。
      final String? rawContent = await _cacheGateway.getChapterContent(
        book.bookUrl,
        chapter.url,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (rawContent == null ||
          rawContent.trim().isEmpty ||
          !_isCurrent(
            userId: userId,
            userGeneration: userGeneration,
            taskGeneration: taskGeneration,
            processingToken: processingToken,
          )) {
        return;
      }
      /// 原始正文命中后才确认最终配置，避免无内容时增加兼容迁移或规则查询。
      final ReaderDisplayConfig config =
          await _cacheGateway.getDisplayConfig(book.bookUrl);
      if (!_isCurrent(
        userId: userId,
        userGeneration: userGeneration,
        taskGeneration: taskGeneration,
        processingToken: processingToken,
      )) {
        return;
      }
      cacheToken = _processedContentCache.begin(
        userId: userId,
        userGeneration: userGeneration,
        bookUrl: book.bookUrl,
        chapterUrl: chapter.url,
        useReplaceRules: config.useReplaceRules,
        chineseConversionMode: config.chineseConversionMode,
        reSegmentContent: config.reSegmentContent,
        replaceRuleRevision: _replaceRuleGateway.contentRevision,
      );
      if (_processedContentCache.take(cacheToken) != null) {
        return;
      }
      final List<ReplaceRule> rules = config.useReplaceRules
          ? await _replaceRuleGateway.getEnabledContentRules(
              book.name,
              book.origin,
            )
          : const <ReplaceRule>[];
      if (!_isCurrent(
        userId: userId,
        userGeneration: userGeneration,
        taskGeneration: taskGeneration,
        processingToken: processingToken,
      )) {
        return;
      }
      final ReaderChapterContent content = await _textProcessor.process(
        book: book,
        chapter: chapter,
        displayTitle: chapter.title,
        rawContent: rawContent,
        replaceRules: rules,
        useReplaceRules: config.useReplaceRules,
        chineseConversionMode: config.chineseConversionMode,
        reSegmentContent: config.reSegmentContent,
        fromCache: true,
        cancellationToken: processingToken,
      );
      if (_isCurrent(
        userId: userId,
        userGeneration: userGeneration,
        taskGeneration: taskGeneration,
        processingToken: processingToken,
      )) {
        _processedContentCache.store(cacheToken, content);
      }
    } on ReaderTextProcessCancelledException {
      // 前台阅读、内存压力、账号切换或销毁主动取消，不需要降级为启动错误。
    } finally {
      if (cacheToken != null) {
        _processedContentCache.end(cacheToken);
      }
      if (identical(_activeProcessingToken, processingToken)) {
        _activeProcessingToken = null;
      }
    }
  }

  /// 按稳定章节索引定位当前章；卷标题或目录偏差时选择最近的可读章节。
  BookChapter? _resolveReadableChapter(
    Book book,
    List<BookChapter> chapters,
  ) {
    if (chapters.isEmpty) {
      return null;
    }
    /// 优先匹配持久化章节索引，避免目录中的卷标题让列表位置与章节索引偏移。
    int targetPosition = chapters.indexWhere(
      (BookChapter chapter) => chapter.index == book.durChapterIndex,
    );
    if (targetPosition < 0) {
      targetPosition = book.durChapterIndex
          .clamp(0, chapters.length - 1)
          .toInt();
    }
    for (int distance = 0; distance < chapters.length; distance += 1) {
      final int forward = targetPosition + distance;
      if (forward < chapters.length && !chapters[forward].isVolume) {
        return chapters[forward];
      }
      final int backward = targetPosition - distance;
      if (distance > 0 &&
          backward >= 0 &&
          !chapters[backward].isVolume) {
        return chapters[backward];
      }
    }
    return null;
  }

  /// 核对用户、任务代次和取消状态，避免任何晚到结果跨边界发布。
  bool _isCurrent({
    required int userId,
    required int userGeneration,
    required int taskGeneration,
    required ReaderTextProcessCancellationToken processingToken,
  }) {
    return _preloadAllowed &&
        taskGeneration == _taskGeneration &&
        !processingToken.isCancelled &&
        _currentUserScope.matches(
          expectedUserId: userId,
          expectedGeneration: userGeneration,
        );
  }

  /// 取消当前处理并使所有已开始的本地查询和旧结果失效。
  void _cancelActiveTask() {
    _taskGeneration += 1;
    _activeProcessingToken?.cancel();
    _activeProcessingToken = null;
  }
}
