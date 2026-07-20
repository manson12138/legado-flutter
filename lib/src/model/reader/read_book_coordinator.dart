import 'dart:async';
import 'dart:collection';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/gateway/replace_rule_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/replace_rule.dart';
import '../../help/logging/app_logger.dart';
import '../web_book/standard_source_service.dart';
import '../web_book/standard_source_parser.dart';
import '../local_book/local_book_parser.dart';
import '../local_book/local_book_service.dart';
import 'reader_text_processor.dart';

/// 阅读正文管线或书源边界失败时抛出的明确错误。
final class ReadBookException implements Exception {
  /// 创建可安全展示的阅读错误。
  const ReadBookException(this.message);

  /// 不包含正文、Cookie 或请求头的错误摘要。
  final String message;

  @override
  String toString() => 'ReadBookException($message)';
}

/// 对应 Android ReadBook 的第一批协调职责：缓存、正文获取、处理、取消和相邻章预加载。
final class ReadBookCoordinator {
  /// 创建页面生命周期独占的正文协调器。
  ReadBookCoordinator({
    required BookSourceGateway sourceGateway,
    required ReplaceRuleGateway replaceRuleGateway,
    required ReaderCacheGateway cacheGateway,
    required StandardBookSourceService standardService,
    required LocalBookContentService localBookContentService,
    required ReaderTextProcessor textProcessor,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
  }) : _sourceGateway = sourceGateway,
       _replaceRuleGateway = replaceRuleGateway,
       _cacheGateway = cacheGateway,
       _standardService = standardService,
       _localBookContentService = localBookContentService,
       _textProcessor = textProcessor,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger;

  /// 书源读取边界。
  final BookSourceGateway _sourceGateway;

  /// 替换规则读取边界。
  final ReplaceRuleGateway _replaceRuleGateway;

  /// 正文和配置缓存边界。
  final ReaderCacheGateway _cacheGateway;

  /// 普通书源正文网络与规则服务。
  final StandardBookSourceService _standardService;

  /// M08.1 本地书目标章节正文读取服务。
  final LocalBookContentService _localBookContentService;

  /// 后台 isolate 正文处理器。
  final ReaderTextProcessor _textProcessor;

  /// HTTP 取消令牌工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 【搜书诊断日志】项目统一日志接口，用于记录正文缓存、获取、处理与预加载。
  final AppLogger _logger;

  /// 最多保留当前章和前后章的内存 LRU 缓存。
  final LinkedHashMap<String, ReaderChapterContent> _memoryCache = LinkedHashMap<String, ReaderChapterContent>();

  /// 当前用户可见章节请求令牌，优先级高于预加载。
  HttpCancellationToken? _currentToken;

  /// 相邻章节预加载令牌集合。
  final List<HttpCancellationToken> _preloadTokens = <HttpCancellationToken>[];

  /// 按章节 URL 保存连续预下载失败次数，达到三次后停止自动重试。
  final Map<String, int> _preloadFailureCounts = <String, int>{};

  /// 每次取消或替换预下载队列时递增，阻止旧 worker 继续领取新任务。
  int _preloadGeneration = 0;

  /// 当前请求世代，确保快速切章后的旧结果不能覆盖新章节。
  int _generation = 0;

  /// 加载当前可见章节，按内存缓存、持久缓存、网络获取、后台处理顺序执行。
  Future<ReaderChapterContent> loadChapter({
    required Book book,
    required BookChapter chapter,
    required ReaderDisplayConfig config,
    bool forceRefresh = false,
  }) async {
    _generation += 1;
    /// 当前请求独占世代。
    final int generation = _generation;
    /// 【搜书诊断日志】当前可见章节不可逆标识。
    final String chapterId = appLogDiagnosticId(chapter.url);
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '正文协调器接收可见章节 generation=$generation chapterId=$chapterId '
          'forceRefresh=$forceRefresh replaceRules=${config.useReplaceRules}',
    );
    _currentToken?.cancel('切换到新的阅读章节');
    _cancelPreloads('当前章节请求优先');
    /// 当前可见请求令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _currentToken = token;
    try {
      /// 完成缓存、请求和处理后的正文。
      final ReaderChapterContent content = await _load(
        book: book,
        chapter: chapter,
        config: config,
        token: token,
        forceRefresh: forceRefresh,
      );
      if (generation != _generation || token.isCancelled) {
        _logger.info(
          tag: bookReaderContentLogTag,
          message: '正文协调器结果已取消 generation=$generation currentGeneration=$_generation '
              'chapterId=$chapterId tokenCancelled=${token.isCancelled}',
        );
        throw const ReadBookException('章节请求已取消');
      }
      _logger.info(
        tag: bookReaderContentLogTag,
        message: '正文协调器返回可见章节 generation=$generation chapterId=$chapterId '
            'textLength=${content.text.length} fromCache=${content.fromCache}',
      );
      return content;
    } finally {
      if (identical(_currentToken, token)) {
        _currentToken = null;
      }
    }
  }

  /// 在当前章节成功后按 Android 范围并发预下载前后章节，失败不会影响当前阅读。
  Future<void> preloadAdjacent({
    required Book book,
    required List<BookChapter> chapters,
    required int currentIndex,
    required ReaderDisplayConfig config,
  }) async {
    _cancelPreloads('开始新的相邻章节预加载');
    /// 本轮预下载队列的稳定世代。
    final int preloadGeneration = _preloadGeneration;
    /// 用户配置的受控预下载数量。
    final int preDownloadCount = config.preDownloadCount.clamp(0, 20).toInt();
    if (preDownloadCount == 0) {
      return;
    }
    /// 按下一章、上一章、后续范围和前序范围顺序保存候选章节。
    final List<int> candidateIndices = <int>[currentIndex + 1, currentIndex - 1];
    /// 从当前章加二开始的向后预下载偏移。
    int forwardOffset = 2;
    while (forwardOffset <= preDownloadCount) {
      candidateIndices.add(currentIndex + forwardOffset);
      forwardOffset += 1;
    }
    /// 向前预下载最多五章的受控数量。
    final int backwardCount = preDownloadCount.clamp(0, 5).toInt();
    /// 从当前章减二开始的向前预下载偏移。
    int backwardOffset = 2;
    while (backwardOffset <= backwardCount) {
      candidateIndices.add(currentIndex - backwardOffset);
      backwardOffset += 1;
    }
    /// 去除越界、卷标题、重复项和已经连续失败三次的稳定候选索引。
    final List<int> candidates = <int>[];
    /// 已经加入本轮队列的章节索引。
    final Set<int> seenIndices = <int>{};
    for (final int index in candidateIndices) {
      if (index < 0 ||
          index >= chapters.length ||
          chapters[index].isVolume ||
          !seenIndices.add(index) ||
          (_preloadFailureCounts[chapters[index].url] ?? 0) >= 3) {
        continue;
      }
      candidates.add(index);
    }
    _logger.debug(
      tag: bookReaderContentLogTag,
      message: '相邻章节预加载开始 currentIndex=$currentIndex candidateCount=${candidates.length}',
    );
    /// 下一个等待固定 worker 领取的候选位置。
    int nextCandidate = 0;

    /// 执行单个最多并发两个的预下载 worker。
    Future<void> worker() async {
      while (_currentToken == null &&
          preloadGeneration == _preloadGeneration &&
          nextCandidate < candidates.length) {
        /// 当前 worker 独占领取的候选列表位置。
        final int candidatePosition = nextCandidate;
        nextCandidate += 1;
        /// 当前需要预下载的章节索引。
        final int index = candidates[candidatePosition];
        /// 当前预加载令牌。
        final HttpCancellationToken token = _cancellationTokenFactory();
        _preloadTokens.add(token);
        try {
          await _load(
            book: book,
            chapter: chapters[index],
            config: config,
            token: token,
          );
          _preloadFailureCounts.remove(chapters[index].url);
        } on Object catch (error) {
          if (token.isCancelled || preloadGeneration != _preloadGeneration) {
            continue;
          }
          /// 当前章节累计预下载失败次数。
          final int failureCount =
              (_preloadFailureCounts[chapters[index].url] ?? 0) + 1;
          _preloadFailureCounts[chapters[index].url] = failureCount;
          /// 【搜书诊断日志】预下载失败只更新内部状态，不污染当前正文错误。
          _logger.warning(
            tag: bookReaderContentLogTag,
            message: '章节预下载失败 chapterIndex=$index failureCount=$failureCount '
                'chapterId=${appLogDiagnosticId(chapters[index].url)}',
            error: error,
          );
        } finally {
          _preloadTokens.remove(token);
        }
      }
    }

    /// 实际预下载 worker 数量，Android 对齐上限为 2。
    final int workerCount = candidates.length.clamp(0, 2).toInt();
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (int index) => worker()),
    );
  }

  /// 释放当前请求、预加载和有限内存缓存。
  void dispose() {
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '正文协调器释放 generation=$_generation memoryCacheCount=${_memoryCache.length} '
          'preloadCount=${_preloadTokens.length} hasCurrentRequest=${_currentToken != null}',
    );
    _generation += 1;
    _currentToken?.cancel('阅读页面已关闭');
    _currentToken = null;
    _cancelPreloads('阅读页面已关闭');
    _memoryCache.clear();
    _preloadFailureCounts.clear();
  }

  /// 清除指定章节的内存处理结果缓存。
  ///
  /// 单章换源或离线下载把新正文直接写入持久缓存后，若该章节此刻正被阅读，内存 LRU
  /// 里仍会留着旧正文——不清掉的话，下一次 [loadChapter] 会先命中这份过期内存结果，
  /// 用户看不到刚替换或刚下载的新内容，需要等内存缓存自然被挤出才会生效。
  void invalidateChapter(String chapterUrl) {
    _memoryCache.remove('$chapterUrl#replace=true');
    _memoryCache.remove('$chapterUrl#replace=false');
  }

  /// iOS/Android 触发内存警告时取消非关键预加载并清空可重建的章节内存缓存。
  ///
  /// 当前可见正文仍由 ReaderUiState 持有，稳定锚点和持久缓存不受影响，因此页面可以继续
  /// 阅读；下一次切章按原管线从持久缓存或书源恢复。
  void handleMemoryPressure() {
    _cancelPreloads('系统内存压力');
    _memoryCache.clear();
  }

  /// 执行单章缓存、网络和处理管线。
  Future<ReaderChapterContent> _load({
    required Book book,
    required BookChapter chapter,
    required ReaderDisplayConfig config,
    required HttpCancellationToken token,
    bool forceRefresh = false,
  }) async {
    /// 【搜书诊断日志】当前正文管线章节不可逆标识。
    final String chapterId = appLogDiagnosticId(chapter.url);
    /// 【搜书诊断日志】单章缓存、网络与处理总耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    /// 配置参与缓存键，替换规则开关变化时不复用旧处理结果。
    final String memoryKey = '${chapter.url}#replace=${config.useReplaceRules}';
    if (!forceRefresh) {
      /// 命中的内存处理结果。
      final ReaderChapterContent? memory = _memoryCache.remove(memoryKey);
      if (memory != null) {
        _memoryCache[memoryKey] = memory;
        _logger.debug(
          tag: bookReaderContentLogTag,
          message: '章节命中内存缓存 chapterId=$chapterId textLength=${memory.text.length} '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
        return memory;
      }
    }
    /// 持久缓存的原始正文。
    String? rawContent;
    /// 优先使用书源正文标题，持久缓存回退目录标题。
    String displayTitle = chapter.title;
    if (!forceRefresh) {
      rawContent = await _cacheGateway.getChapterContent(
        book.bookUrl,
        chapter.url,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    /// 是否命中持久正文缓存。
    final bool fromCache = rawContent != null;
    _logger.debug(
      tag: bookReaderContentLogTag,
      message: '章节持久缓存查询完成 chapterId=$chapterId hit=$fromCache forceRefresh=$forceRefresh',
    );
    if (rawContent == null && book.origin == 'loc_book') {
      try {
        _logger.info(tag: bookReaderContentLogTag, message: '章节读取本地书内容开始 chapterId=$chapterId');
        rawContent = await _localBookContentService.loadChapter(book, chapter);
      } on LocalBookException catch (error) {
        _logger.error(
          tag: bookReaderContentLogTag,
          message: '章节读取本地书内容失败 chapterId=$chapterId',
          error: error,
        );
        throw ReadBookException(error.message);
      }
    }
    if (rawContent == null) {
      /// 当前网络书籍对应书源。
      final BookSource? source = await _sourceGateway.getByUrl(book.origin);
      if (source == null) {
        _logger.warning(
          tag: bookReaderContentLogTag,
          message: '章节网络加载终止 chapterId=$chapterId reason=sourceMissing',
        );
        throw const ReadBookException('原书源已不存在');
      }
      /// 普通规则或 JavaScript 混合链路解析后的正文页。
      final ParsedContentPage parsed = await _standardService.loadContent(
        source: source,
        chapter: chapter,
        cancellationToken: token,
      );
      _logger.info(
        tag: bookReaderContentLogTag,
        message: '章节网络正文取得 chapterId=$chapterId contentLength=${parsed.content.length}',
      );
      rawContent = parsed.content;
      if (parsed.title?.trim().isNotEmpty == true) {
        displayTitle = parsed.title?.trim() ?? chapter.title;
      }
    }
    if (!fromCache) {
      if (rawContent.trim().isEmpty) {
        _logger.warning(tag: bookReaderContentLogTag, message: '章节正文为空 chapterId=$chapterId');
        throw const ReadBookException('章节正文为空');
      }
      /// 网络书和本地书都缓存七天；重新导入会生成新的稳定内容身份。
      await _cacheGateway.saveChapterContent(
        book.bookUrl,
        chapter.url,
        rawContent,
        DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch,
      );
      _logger.debug(
        tag: bookReaderContentLogTag,
        message: '章节原始正文缓存完成 chapterId=$chapterId contentLength=${rawContent.length}',
      );
    }
    if (token.isCancelled) {
      throw const ReadBookException('章节请求已取消');
    }
    /// 当前书籍范围内的正文替换规则。
    final List<ReplaceRule> rules = config.useReplaceRules
        ? await _replaceRuleGateway.getEnabledContentRules(book.name, book.origin)
        : const <ReplaceRule>[];
    _logger.debug(
      tag: bookReaderContentLogTag,
      message: '章节正文处理开始 chapterId=$chapterId replaceRuleCount=${rules.length} '
          'rawContentLength=${rawContent.length}',
    );
    /// 后台净化和分块结果。
    final ReaderChapterContent content;
    try {
      content = await _textProcessor.process(
        book: book,
        chapter: chapter,
        displayTitle: displayTitle,
        rawContent: rawContent,
        replaceRules: rules,
        useReplaceRules: config.useReplaceRules,
        fromCache: fromCache,
      );
    } on ReaderTextProcessException catch (error) {
      _logger.error(
        tag: bookReaderContentLogTag,
        message: '章节正文处理失败 chapterId=$chapterId',
        error: error,
      );
      throw ReadBookException(error.message);
    }
    _memoryCache[memoryKey] = content;
    while (_memoryCache.length > 3) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '章节正文处理完成 chapterId=$chapterId textLength=${content.text.length} '
          'blockCount=${content.blocks.length} effectiveReplaceRuleCount=${content.effectiveReplaceRuleCount} '
          'fromCache=${content.fromCache} elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    return content;
  }

  /// 取消全部低优先级预加载令牌。
  void _cancelPreloads(String reason) {
    _preloadGeneration += 1;
    if (_preloadTokens.isNotEmpty) {
      /// 【搜书诊断日志】取消原因由内部固定文案提供，不包含用户输入。
      _logger.debug(
        tag: bookReaderContentLogTag,
        message: '取消相邻章节预加载 count=${_preloadTokens.length} reason=$reason',
      );
    }
    for (final HttpCancellationToken token in List<HttpCancellationToken>.of(_preloadTokens)) {
      token.cancel(reason);
    }
    _preloadTokens.clear();
  }

}
