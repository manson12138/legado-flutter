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
  }) : _sourceGateway = sourceGateway,
       _replaceRuleGateway = replaceRuleGateway,
       _cacheGateway = cacheGateway,
       _standardService = standardService,
       _localBookContentService = localBookContentService,
       _textProcessor = textProcessor,
       _cancellationTokenFactory = cancellationTokenFactory;

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

  /// 最多保留当前章和前后章的内存 LRU 缓存。
  final LinkedHashMap<String, ReaderChapterContent> _memoryCache = LinkedHashMap<String, ReaderChapterContent>();

  /// 当前用户可见章节请求令牌，优先级高于预加载。
  HttpCancellationToken? _currentToken;

  /// 相邻章节预加载令牌集合。
  final List<HttpCancellationToken> _preloadTokens = <HttpCancellationToken>[];

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
        throw const ReadBookException('章节请求已取消');
      }
      return content;
    } finally {
      if (identical(_currentToken, token)) {
        _currentToken = null;
      }
    }
  }

  /// 在当前章节成功后顺序预加载前后章节，失败不会影响当前阅读。
  Future<void> preloadAdjacent({
    required Book book,
    required List<BookChapter> chapters,
    required int currentIndex,
    required ReaderDisplayConfig config,
  }) async {
    _cancelPreloads('开始新的相邻章节预加载');
    /// 相邻且可阅读的章节索引，下一章优先。
    final List<int> candidates = <int>[currentIndex + 1, currentIndex - 1]
        .where((int index) => index >= 0 && index < chapters.length && !chapters[index].isVolume)
        .toList(growable: false);
    for (final int index in candidates) {
      if (_currentToken != null) {
        return;
      }
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
      } on Object {
        // 预加载失败只丢弃该章，当前阅读状态不受影响。
      } finally {
        _preloadTokens.remove(token);
      }
    }
  }

  /// 释放当前请求、预加载和有限内存缓存。
  void dispose() {
    _generation += 1;
    _currentToken?.cancel('阅读页面已关闭');
    _currentToken = null;
    _cancelPreloads('阅读页面已关闭');
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
    /// 配置参与缓存键，替换规则开关变化时不复用旧处理结果。
    final String memoryKey = '${chapter.url}#replace=${config.useReplaceRules}';
    if (!forceRefresh) {
      /// 命中的内存处理结果。
      final ReaderChapterContent? memory = _memoryCache.remove(memoryKey);
      if (memory != null) {
        _memoryCache[memoryKey] = memory;
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
    if (rawContent == null && book.origin == 'loc_book') {
      try {
        rawContent = await _localBookContentService.loadChapter(book, chapter);
      } on LocalBookException catch (error) {
        throw ReadBookException(error.message);
      }
    }
    if (rawContent == null) {
      /// 当前网络书籍对应书源。
      final BookSource? source = await _sourceGateway.getByUrl(book.origin);
      if (source == null) {
        throw const ReadBookException('原书源已不存在');
      }
      if (_requiresJavaScript(source, chapter)) {
        throw const ReadBookException('该章节依赖 JavaScript，需先完成 M04 真机兼容验收');
      }
      /// 普通书源解析后的正文页。
      final ParsedContentPage parsed = await _standardService.loadContent(
        source: source,
        chapter: chapter,
        cancellationToken: token,
      );
      rawContent = parsed.content;
      if (parsed.title?.trim().isNotEmpty == true) {
        displayTitle = parsed.title?.trim() ?? chapter.title;
      }
    }
    if (!fromCache) {
      if (rawContent.trim().isEmpty) {
        throw const ReadBookException('章节正文为空');
      }
      /// 网络书和本地书都缓存七天；重新导入会生成新的稳定内容身份。
      await _cacheGateway.saveChapterContent(
        book.bookUrl,
        chapter.url,
        rawContent,
        DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch,
      );
    }
    if (token.isCancelled) {
      throw const ReadBookException('章节请求已取消');
    }
    /// 当前书籍范围内的正文替换规则。
    final List<ReplaceRule> rules = config.useReplaceRules
        ? await _replaceRuleGateway.getEnabledContentRules(book.name, book.origin)
        : const <ReplaceRule>[];
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
      throw ReadBookException(error.message);
    }
    _memoryCache[memoryKey] = content;
    while (_memoryCache.length > 3) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    return content;
  }

  /// 取消全部低优先级预加载令牌。
  void _cancelPreloads(String reason) {
    for (final HttpCancellationToken token in List<HttpCancellationToken>.of(_preloadTokens)) {
      token.cancel(reason);
    }
    _preloadTokens.clear();
  }

  /// 判断普通规则正文服务不能安全执行的 JavaScript 字段或规则片段。
  bool _requiresJavaScript(BookSource source, BookChapter chapter) {
    if (source.jsLib?.trim().isNotEmpty == true) {
      return true;
    }
    /// 正文链路可能包含脚本的原始文本。
    final String rules = <String?>[
      source.ruleContent,
      chapter.url,
    ].whereType<String>().join('\n');
    return RegExp(
      r'@js:|<js>|js@|Packages\.|JavaImporter|java\.',
      caseSensitive: false,
    ).hasMatch(rules);
  }
}
