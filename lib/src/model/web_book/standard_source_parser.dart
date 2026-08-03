import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../api/http/http_contract.dart';
import '../../api/js/js_engine.dart';
import '../../api/js/script_context.dart';
import '../../constant/book_source_type.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/reader_content_markup.dart';
import '../../domain/model/search_book.dart';
import '../analyze_rule/legado_javascript_service.dart';
import '../analyze_rule/legado_rule_evaluator.dart';
import '../analyze_rule/source_rules.dart';
import '../analyze_rule/standard_rule_engine.dart';

/// 【原生规则容错】非核心字段解析失败后返回主 isolate 的告警信息。
final class StandardParseWarning {
  /// 创建不可变字段解析告警。
  const StandardParseWarning({
    required this.field,
    required this.message,
    this.javaScriptError,
  });

  /// 失败字段名称。
  final String field;

  /// 不包含页面正文的异常摘要。
  final String message;

  /// 【FLUTTER_JS_COMPAT_LOG】可选字段产生的结构化 JavaScript 异常，供上层统一脱敏记录。
  final JsEngineException? javaScriptError;
}

/// 【原生规则容错】搜索结果及可恢复字段告警。
final class ParsedSearchResult {
  /// 创建不可变搜索解析结果。
  ParsedSearchResult({required List<SearchBook> books, required List<StandardParseWarning> warnings})
    : books = List<SearchBook>.unmodifiable(books),
      warnings = List<StandardParseWarning>.unmodifiable(warnings);

  /// 成功解析且按详情地址去重后的搜索结果。
  final List<SearchBook> books;

  /// 分类、字数、最新章节、简介或封面解析失败产生的可恢复告警。
  final List<StandardParseWarning> warnings;
}

/// 详情页解析结果；由后续 UseCase 决定是否写回书架。
final class ParsedBookInfo {
  /// 创建不可变详情结果。
  ParsedBookInfo({
    required this.name,
    required this.author,
    this.intro,
    this.kind,
    this.coverUrl,
    this.tocUrl,
    this.latestChapterTitle,
    this.wordCount,
    List<StandardParseWarning> warnings = const <StandardParseWarning>[],
  }) : warnings = List<StandardParseWarning>.unmodifiable(warnings);

  /// 书名。
  final String name;

  /// 作者。
  final String author;

  /// 简介。
  final String? intro;

  /// 分类。
  final String? kind;

  /// 绝对封面 URL。
  final String? coverUrl;

  /// 绝对目录 URL。
  final String? tocUrl;

  /// 最新章节标题。
  final String? latestChapterTitle;

  /// 字数文本。
  final String? wordCount;

  /// 分类、字数、最新章节、简介或封面解析失败产生的可恢复告警。
  final List<StandardParseWarning> warnings;
}

/// 单页目录解析结果，保留下一页目录地址供编排层继续请求。
final class ParsedTocPage {
  /// 创建不可变目录页结果。
  ParsedTocPage({
    required List<BookChapter> chapters,
    required List<Uri> nextPageUris,
    required this.reverse,
    required this.matchedNodeCount,
    required this.skippedEmptyTitleCount,
    required this.fallbackChapterUrlCount,
  })
    : chapters = List<BookChapter>.unmodifiable(chapters),
      nextPageUris = List<Uri>.unmodifiable(nextPageUris);

  /// 当前页章节。
  final List<BookChapter> chapters;

  /// 下一页目录绝对地址。
  final List<Uri> nextPageUris;

  /// 章节列表规则是否带 Android `-` 反序前缀。
  final bool reverse;

  /// 【FLUTTER_REWRITE_DEBUG_LOG】章节列表规则在当前页面命中的原始节点数量。
  final int matchedNodeCount;

  /// 【FLUTTER_REWRITE_DEBUG_LOG】命中节点中因章节标题为空而被跳过的数量。
  final int skippedEmptyTitleCount;

  /// 【FLUTTER_REWRITE_DEBUG_LOG】因章节 URL 为空而使用兼容回退地址的数量。
  final int fallbackChapterUrlCount;
}

/// 单页正文解析结果，保留副正文与下一页地址。
final class ParsedContentPage {
  /// 创建不可变正文页结果。
  ParsedContentPage({
    required this.content,
    required List<Uri> nextPageUris,
    this.title,
    this.subContent,
  }) : nextPageUris = List<Uri>.unmodifiable(nextPageUris);

  /// 清理后的正文文本。
  final String content;

  /// 可覆盖章节名称的标题。
  final String? title;

  /// 歌词等副正文。
  final String? subContent;

  /// 下一页正文绝对地址。
  final List<Uri> nextPageUris;
}

/// 在后台 isolate 执行四段普通规则解析。
final class StandardBookSourceParser {
  /// 创建普通规则与 JavaScript 混合解析入口。
  StandardBookSourceParser({required LegadoJavaScriptService javaScriptService})
    : _ruleEvaluator = LegadoRuleEvaluator(javaScriptService);

  /// 仅在规则包含脚本时使用的异步混合规则执行器。
  final LegadoRuleEvaluator _ruleEvaluator;

  /// 解析搜索列表；合法空列表与规则异常保持不同结果。
  Future<ParsedSearchResult> parseSearch({
    required BookSource source,
    required String body,
    required Uri finalUri,
    required int receivedAt,
    required String keyword,
    required int page,
    LegadoScriptExecutionState? scriptExecutionState,
    LegadoScriptInteractionPolicy interactionPolicy = LegadoScriptInteractionPolicy.deny,
    HttpCancellationToken? cancellationToken,
  }) {
    if (_ruleEvaluator.containsJavaScript(source.ruleSearch)) {
      return _parseSearchAsync(
        source,
        body,
        finalUri,
        receivedAt,
        keyword,
        page,
        scriptExecutionState,
        interactionPolicy,
        cancellationToken,
      );
    }
    return Isolate.run<ParsedSearchResult>(
      () => _parseSearchSync(source, body, finalUri, receivedAt),
    );
  }

  /// 解析书籍详情。
  Future<ParsedBookInfo> parseBookInfo({
    required BookSource source,
    required Book book,
    LegadoScriptExecutionState? scriptExecutionState,
    required String body,
    required Uri finalUri,
    HttpCancellationToken? cancellationToken,
  }) {
    if (_ruleEvaluator.containsJavaScript(source.ruleBookInfo)) {
      return _parseBookInfoAsync(
        source,
        book,
        scriptExecutionState,
        body,
        finalUri,
        cancellationToken,
      );
    }
    return Isolate.run<ParsedBookInfo>(
      () => _parseBookInfoSync(source, book, body, finalUri),
    );
  }

  /// 解析单页目录。
  Future<ParsedTocPage> parseTocPage({
    required BookSource source,
    required Book book,
    LegadoScriptExecutionState? scriptExecutionState,
    required String body,
    required Uri finalUri,
    required int startIndex,
    HttpCancellationToken? cancellationToken,
  }) {
    /// 强类型目录规则，用于识别无需显式 `@js:` 标记的专属脚本字段。
    final TocSourceRule rule = const BookSourceRuleDecoder().decodeToc(source);
    if (_ruleEvaluator.containsJavaScript(source.ruleToc) ||
        rule.formatJs?.trim().isNotEmpty == true) {
      return _parseTocAsync(
        source,
        book,
        scriptExecutionState,
        body,
        finalUri,
        startIndex,
        cancellationToken,
      );
    }
    return Isolate.run<ParsedTocPage>(
      () => _parseTocSync(source, book, body, finalUri, startIndex),
    );
  }

  /// 解析单页正文。
  Future<ParsedContentPage> parseContentPage({
    required BookSource source,
    required Book book,
    required BookChapter chapter,
    String? nextChapterUrl,
    LegadoScriptExecutionState? scriptExecutionState,
    LegadoScriptOperation scriptOperation = LegadoScriptOperation.content,
    required String body,
    required Uri finalUri,
    HttpCancellationToken? cancellationToken,
  }) {
    if (_ruleEvaluator.containsJavaScript(source.ruleContent)) {
      return _parseContentAsync(
        source,
        book,
        chapter,
        nextChapterUrl,
        scriptExecutionState,
        scriptOperation,
        body,
        finalUri,
        cancellationToken,
      );
    }
    return Isolate.run<ParsedContentPage>(
      () => _parseContentSync(source, chapter, body, finalUri),
    );
  }

  /// 在主 isolate 中异步解析含 JavaScript 的搜索列表。
  Future<ParsedSearchResult> _parseSearchAsync(
    BookSource source,
    String body,
    Uri finalUri,
    int receivedAt,
    String keyword,
    int page,
    LegadoScriptExecutionState? scriptExecutionState,
    LegadoScriptInteractionPolicy interactionPolicy,
    HttpCancellationToken? cancellationToken,
  ) async {
    /// 强类型搜索规则。
    final SearchSourceRule rule = const BookSourceRuleDecoder().decodeSearch(source);
    /// 同时观察 HTTP 取消状态的 JavaScript 取消令牌。
    final JsCancellationToken? jsCancellationToken = _jsCancellationToken(cancellationToken);
    /// 当前搜索规则共享的脚本上下文。
    final LegadoScriptContext scriptContext = LegadoScriptContext(
      source: source,
      baseUri: finalUri,
      result: body,
      key: keyword,
      page: page,
      executionState: scriptExecutionState,
      operation: LegadoScriptOperation.search,
      interactionPolicy: interactionPolicy,
      httpCancellationToken: cancellationToken,
    );
    /// 是否反转最终列表。
    final bool reverse = rule.bookList?.startsWith('-') ?? false;
    /// 列表节点。
    final List<StandardRuleNode> nodes = (await _ruleEvaluator.elements(
      rule: rule.bookList,
      input: body,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    )).values;
    /// 按详情 URL 去重的结果。
    final Map<String, SearchBook> unique = <String, SearchBook>{};
    /// 可选搜索字段的解析告警。
    final List<StandardParseWarning> warnings = <StandardParseWarning>[];
    for (final StandardRuleNode node in nodes) {
      /// 当前书籍节点原始值。
      final Object? input = node.value;
      /// 书名。
      final String name = _cleanName(await _ruleEvaluator.string(
        rule: rule.name,
        input: input,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      ));
      if (name.isEmpty) {
        continue;
      }
      /// 作者。
      final String author = _cleanAuthor(await _ruleEvaluator.string(
        rule: rule.author,
        input: input,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      ));
      /// 详情地址原始值。
      final String rawBookUrl = (await _ruleEvaluator.string(
        rule: rule.bookUrl,
        input: input,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      )).trim();
      /// 绝对详情地址。
      final String bookUrl = _absoluteOrFallback(finalUri, rawBookUrl).toString();
      /// 封面原始地址。
      final String rawCoverUrl = (await _optionalAsyncString(
        rule: rule.coverUrl,
        input: input,
        context: scriptContext,
        field: 'coverUrl',
        warnings: warnings,
        cancellationToken: jsCancellationToken,
      )).trim();
      /// 分类列表。
      final List<String> kinds = await _optionalAsyncStrings(
        rule: rule.kind,
        input: input,
        context: scriptContext,
        field: 'kind',
        warnings: warnings,
        cancellationToken: jsCancellationToken,
      );
      /// 简介字段。
      final String intro = await _optionalAsyncString(
        rule: rule.intro,
        input: input,
        context: scriptContext,
        field: 'intro',
        warnings: warnings,
        cancellationToken: jsCancellationToken,
      );
      /// 字数字段。
      final String wordCount = await _optionalAsyncString(
        rule: rule.wordCount,
        input: input,
        context: scriptContext,
        field: 'wordCount',
        warnings: warnings,
        cancellationToken: jsCancellationToken,
      );
      /// 最新章节字段。
      final String latestChapter = await _optionalAsyncString(
        rule: rule.lastChapter,
        input: input,
        context: scriptContext,
        field: 'lastChapter',
        warnings: warnings,
        cancellationToken: jsCancellationToken,
      );
      unique.putIfAbsent(
        bookUrl,
        () => SearchBook(
          bookUrl: bookUrl,
          origin: source.bookSourceUrl,
          originName: source.bookSourceName,
          name: name,
          author: author,
          type: bookTypeFromSourceType(source.bookSourceType),
          kind: _nullable(kinds.join(','), maxLength: 1000),
          coverUrl: rawCoverUrl.isEmpty ? null : finalUri.resolve(rawCoverUrl).toString(),
          intro: _nullable(_plainText(intro), maxLength: 5000),
          wordCount: _nullable(wordCount),
          latestChapterTitle: _nullable(latestChapter),
          time: receivedAt,
          originOrder: source.customOrder,
          sourceScore: source.sourceScore,
          pinned: source.pinned,
        ),
      );
    }
    /// 可变结果用于处理反序规则。
    final List<SearchBook> result = unique.values.toList(growable: false);
    return ParsedSearchResult(
      books: reverse ? result.reversed.toList(growable: false) : result,
      warnings: warnings,
    );
  }

  /// 在主 isolate 中异步解析含 JavaScript 的书籍详情。
  Future<ParsedBookInfo> _parseBookInfoAsync(
    BookSource source,
    Book book,
    LegadoScriptExecutionState? scriptExecutionState,
    String body,
    Uri finalUri,
    HttpCancellationToken? cancellationToken,
  ) async {
    /// 强类型详情规则。
    final BookInfoSourceRule rule = const BookSourceRuleDecoder().decodeBookInfo(source);
    /// 同时观察 HTTP 取消状态的 JavaScript 取消令牌。
    final JsCancellationToken? jsCancellationToken = _jsCancellationToken(cancellationToken);
    /// 当前详情规则共享的脚本上下文。
    final LegadoScriptContext scriptContext = LegadoScriptContext(
      source: source,
      baseUri: finalUri,
      book: book,
      executionState: scriptExecutionState,
      operation: LegadoScriptOperation.bookInfo,
      result: body,
      httpCancellationToken: cancellationToken,
    );
    /// `init` 规则后的详情上下文。
    final Object? context = rule.init == null || rule.init?.trim().isEmpty == true
        ? body
        : (await _ruleEvaluator.elements(
              rule: rule.init,
              input: body,
              context: scriptContext,
              cancellationToken: jsCancellationToken,
            ))
            .firstOrNull
            ?.value ??
            body;
    /// 规则解析书名。
    final String parsedName = _cleanName(await _ruleEvaluator.string(
      rule: rule.name,
      input: context,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    ));
    /// 规则解析作者。
    final String parsedAuthor = _cleanAuthor(await _ruleEvaluator.string(
      rule: rule.author,
      input: context,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    ));
    /// 详情可选字段的解析告警。
    final List<StandardParseWarning> warnings = <StandardParseWarning>[];
    /// 封面相对地址。
    final String cover = (await _optionalAsyncString(
      rule: rule.coverUrl,
      input: context,
      context: scriptContext,
      field: 'coverUrl',
      warnings: warnings,
      cancellationToken: jsCancellationToken,
    )).trim();
    /// 目录相对地址。
    final String toc = (await _ruleEvaluator.string(
      rule: rule.tocUrl,
      input: context,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    )).trim();
    /// Android 用非空 `canReName` 规则决定是否覆盖已有书名作者。
    final bool canRename = rule.canReName?.trim().isNotEmpty == true;
    /// 简介字段。
    final String intro = await _optionalAsyncString(
      rule: rule.intro,
      input: context,
      context: scriptContext,
      field: 'intro',
      warnings: warnings,
      cancellationToken: jsCancellationToken,
    );
    /// 分类字段。
    final List<String> kinds = await _optionalAsyncStrings(
      rule: rule.kind,
      input: context,
      context: scriptContext,
      field: 'kind',
      warnings: warnings,
      cancellationToken: jsCancellationToken,
    );
    /// 最新章节字段。
    final String latestChapter = await _optionalAsyncString(
      rule: rule.lastChapter,
      input: context,
      context: scriptContext,
      field: 'lastChapter',
      warnings: warnings,
      cancellationToken: jsCancellationToken,
    );
    /// 字数字段。
    final String wordCount = await _optionalAsyncString(
      rule: rule.wordCount,
      input: context,
      context: scriptContext,
      field: 'wordCount',
      warnings: warnings,
      cancellationToken: jsCancellationToken,
    );
    return ParsedBookInfo(
      name: parsedName.isNotEmpty && (canRename || book.name.isEmpty) ? parsedName : book.name,
      author: parsedAuthor.isNotEmpty && (canRename || book.author.isEmpty)
          ? parsedAuthor
          : book.author,
      intro: _nullable(_plainText(intro), maxLength: 5000),
      kind: _nullable(kinds.join(','), maxLength: 1000),
      coverUrl: cover.isEmpty ? book.coverUrl : finalUri.resolve(cover).toString(),
      tocUrl: toc.isEmpty ? book.bookUrl : finalUri.resolve(toc).toString(),
      latestChapterTitle: _nullable(latestChapter),
      wordCount: _nullable(wordCount),
      warnings: warnings,
    );
  }

  /// 在主 isolate 中异步解析含 JavaScript 的单页目录。
  Future<ParsedTocPage> _parseTocAsync(
    BookSource source,
    Book book,
    LegadoScriptExecutionState? scriptExecutionState,
    String body,
    Uri finalUri,
    int startIndex,
    HttpCancellationToken? cancellationToken,
  ) async {
    /// 强类型目录规则。
    final TocSourceRule rule = const BookSourceRuleDecoder().decodeToc(source);
    /// 同时观察 HTTP 取消状态的 JavaScript 取消令牌。
    final JsCancellationToken? jsCancellationToken = _jsCancellationToken(cancellationToken);
    /// 当前目录规则共享的脚本上下文。
    final LegadoScriptContext scriptContext = LegadoScriptContext(
      source: source,
      baseUri: finalUri,
      book: book,
      executionState: scriptExecutionState,
      operation: LegadoScriptOperation.toc,
      result: body,
      httpCancellationToken: cancellationToken,
    );
    /// 章节节点。
    final List<StandardRuleNode> nodes = (await _ruleEvaluator.elements(
      rule: rule.chapterList,
      input: body,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    )).values;
    /// 当前页章节。
    final List<BookChapter> chapters = <BookChapter>[];
    /// 因标题为空而跳过的节点数。
    int skippedEmptyTitleCount = 0;
    /// 因 URL 为空而使用兼容回退的节点数。
    int fallbackChapterUrlCount = 0;
    for (int offset = 0; offset < nodes.length; offset += 1) {
      /// 当前章节节点原始值。
      final Object? context = nodes[offset].value;
      /// 规则得到的章节标题。
      String title = (await _ruleEvaluator.string(
        rule: rule.chapterName,
        input: context,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      )).trim();
      if (rule.formatJs?.trim().isNotEmpty == true) {
        title = (await _ruleEvaluator.string(
          rule: _asJavaScriptRule(rule.formatJs ?? ''),
          input: title,
          context: scriptContext,
          cancellationToken: jsCancellationToken,
        )).trim();
      }
      if (title.isEmpty) {
        skippedEmptyTitleCount += 1;
        continue;
      }
      /// 是否为卷标题。
      final bool isVolume = _isTrue(await _ruleEvaluator.string(
        rule: rule.isVolume,
        input: context,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      ));
      /// 章节原始 URL。
      final String rawUrl = (await _ruleEvaluator.string(
        rule: rule.chapterUrl,
        input: context,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      )).trim();
      if (rawUrl.isEmpty) {
        fallbackChapterUrlCount += 1;
      }
      /// Android 对空章节 URL 的兼容回退。
      final String chapterUrl = rawUrl.isEmpty
          ? (isVolume ? '$title${startIndex + offset}' : finalUri.toString())
          : finalUri.resolve(rawUrl).toString();
      /// VIP 标识。
      final bool isVip = _isTrue(await _ruleEvaluator.string(
        rule: rule.isVip,
        input: context,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      ));
      /// 购买标识。
      final bool isPay = _isTrue(await _ruleEvaluator.string(
        rule: rule.isPay,
        input: context,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      ));
      /// 更新时间或附加标签。
      final String updateTime = await _ruleEvaluator.string(
        rule: rule.updateTime,
        input: context,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      );
      chapters.add(
        BookChapter(
          url: chapterUrl,
          title: title,
          bookUrl: book.bookUrl,
          index: startIndex + chapters.length,
          isVolume: isVolume,
          baseUrl: finalUri.toString(),
          isVip: isVip,
          isPay: isPay,
          tag: _nullable(updateTime),
        ),
      );
    }
    /// 下一页目录地址。
    final List<Uri> nextUris = _absoluteUris(
      (await _ruleEvaluator.strings(
        rule: rule.nextTocUrl,
        input: body,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      )).values,
      finalUri,
    );
    return ParsedTocPage(
      chapters: chapters,
      nextPageUris: nextUris,
      reverse: rule.chapterList?.startsWith('-') ?? false,
      matchedNodeCount: nodes.length,
      skippedEmptyTitleCount: skippedEmptyTitleCount,
      fallbackChapterUrlCount: fallbackChapterUrlCount,
    );
  }

  /// 在主 isolate 中异步解析含 JavaScript 的单页正文。
  Future<ParsedContentPage> _parseContentAsync(
    BookSource source,
    Book book,
    BookChapter chapter,
    String? nextChapterUrl,
    LegadoScriptExecutionState? scriptExecutionState,
    LegadoScriptOperation scriptOperation,
    String body,
    Uri finalUri,
    HttpCancellationToken? cancellationToken,
  ) async {
    /// 强类型正文规则。
    final ContentSourceRule rule = const BookSourceRuleDecoder().decodeContent(source);
    _rejectNonEmptyJavaScript(rule.payAction, '正文 payAction');
    /// 同时观察 HTTP 取消状态的 JavaScript 取消令牌。
    final JsCancellationToken? jsCancellationToken = _jsCancellationToken(cancellationToken);
    /// 当前正文规则共享的脚本上下文。
    final LegadoScriptContext scriptContext = LegadoScriptContext(
      source: source,
      baseUri: finalUri,
      book: book,
      chapter: chapter,
      nextChapterUrl: nextChapterUrl,
      executionState: scriptExecutionState,
      operation: scriptOperation,
      result: body,
      httpCancellationToken: cancellationToken,
    );
    /// 未格式化正文。
    String content = await _ruleEvaluator.string(
      rule: rule.content,
      input: body,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    );
    if (rule.replaceRegex?.trim().isNotEmpty == true) {
      content = await _ruleEvaluator.string(
        rule: rule.replaceRegex,
        input: content,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      );
    }
    /// 统一 HTML 与段落换行后的正文。
    final String formatted = _formatContent(content, finalUri);
    if (!chapter.isVolume && formatted.trim().isEmpty) {
      throw const StandardRuleException('正文规则匹配成功但内容为空');
    }
    /// 正文标题。
    final String title = await _ruleEvaluator.string(
      rule: rule.title,
      input: body,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    );
    /// 正文副内容。
    final String subContent = await _ruleEvaluator.string(
      rule: rule.subContent,
      input: body,
      context: scriptContext,
      cancellationToken: jsCancellationToken,
    );
    /// 下一页正文地址。
    final List<Uri> nextPageUris = _absoluteUris(
      (await _ruleEvaluator.strings(
        rule: rule.nextContentUrl,
        input: body,
        context: scriptContext,
        cancellationToken: jsCancellationToken,
      )).values,
      finalUri,
    );
    return ParsedContentPage(
      content: formatted,
      title: _nullable(title),
      subContent: _nullable(subContent),
      nextPageUris: nextPageUris,
    );
  }

  /// 将 HTTP 取消令牌适配为 QuickJS 可观察的取消令牌。
  JsCancellationToken? _jsCancellationToken(HttpCancellationToken? token) {
    return token == null ? null : _HttpBackedJsCancellationToken(token);
  }

  /// 为专属 JavaScript 字段补充规则标记，已经带标记的脚本保持原样。
  String _asJavaScriptRule(String script) {
    /// 用于识别已有 JavaScript 标记的小写脚本文本。
    final String normalized = script.trim().toLowerCase();
    if (normalized.startsWith('@js:') || normalized.startsWith('<js>')) {
      return script;
    }
    return '@js:$script';
  }

  /// 解析可选脚本字段，失败时记录告警并返回空文本。
  Future<String> _optionalAsyncString({
    required String? rule,
    required Object? input,
    required LegadoScriptContext context,
    required String field,
    required List<StandardParseWarning> warnings,
    JsCancellationToken? cancellationToken,
  }) async {
    try {
      return await _ruleEvaluator.string(
        rule: rule,
        input: input,
        context: context,
        cancellationToken: cancellationToken,
      );
    } on Exception catch (error) {
      warnings.add(
        StandardParseWarning(
          field: field,
          message: error.toString(),
          javaScriptError: error is JsEngineException ? error : null,
        ),
      );
      return '';
    }
  }

  /// 解析可选脚本字符串列表，失败时记录告警并返回空列表。
  Future<List<String>> _optionalAsyncStrings({
    required String? rule,
    required Object? input,
    required LegadoScriptContext context,
    required String field,
    required List<StandardParseWarning> warnings,
    JsCancellationToken? cancellationToken,
  }) async {
    try {
      return (await _ruleEvaluator.strings(
        rule: rule,
        input: input,
        context: context,
        cancellationToken: cancellationToken,
      )).values;
    } on Exception catch (error) {
      warnings.add(
        StandardParseWarning(
          field: field,
          message: error.toString(),
          javaScriptError: error is JsEngineException ? error : null,
        ),
      );
      return const <String>[];
    }
  }

  /// 同步解析搜索列表；只在工作 isolate 内调用。
  static ParsedSearchResult _parseSearchSync(
    BookSource source,
    String body,
    Uri finalUri,
    int receivedAt,
  ) {
    /// 强类型搜索规则。
    final SearchSourceRule rule = const BookSourceRuleDecoder().decodeSearch(source);
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// 是否反转最终列表。
    final bool reverse = rule.bookList?.startsWith('-') ?? false;
    /// 列表节点。
    final List<StandardRuleNode> nodes = engine.elements(rule.bookList, body).values;
    /// 按详情 URL 去重的结果。
    final Map<String, SearchBook> unique = <String, SearchBook>{};
    /// 【原生规则容错】搜索可选字段的解析告警。
    final List<StandardParseWarning> warnings = <StandardParseWarning>[];
    for (final StandardRuleNode node in nodes) {
      /// 书名。
      final String name = _cleanName(engine.string(rule.name, node.value));
      if (name.isEmpty) {
        continue;
      }
      /// 作者。
      final String author = _cleanAuthor(engine.string(rule.author, node.value));
      /// 详情地址原始值。
      final String rawBookUrl = engine.string(rule.bookUrl, node.value).trim();
      /// 详情绝对地址；Android 未取到地址时会退回当前页。
      final String bookUrl = _absoluteOrFallback(finalUri, rawBookUrl).toString();
      /// 封面原始地址。
      final String rawCoverUrl = _optionalString(
        engine: engine,
        rule: rule.coverUrl,
        input: node.value,
        field: 'coverUrl',
        warnings: warnings,
      ).trim();
      /// 分类列表。
      final List<String> kinds = _optionalStrings(
        engine: engine,
        rule: rule.kind,
        input: node.value,
        field: 'kind',
        warnings: warnings,
      );
      unique.putIfAbsent(
        bookUrl,
        () => SearchBook(
          bookUrl: bookUrl,
          origin: source.bookSourceUrl,
          originName: source.bookSourceName,
          name: name,
          author: author,
          type: bookTypeFromSourceType(source.bookSourceType),
          kind: _nullable(kinds.join(','), maxLength: 1000),
          coverUrl: rawCoverUrl.isEmpty ? null : finalUri.resolve(rawCoverUrl).toString(),
          intro: _nullable(
            _plainText(
              _optionalString(
                engine: engine,
                rule: rule.intro,
                input: node.value,
                field: 'intro',
                warnings: warnings,
              ),
            ),
            maxLength: 5000,
          ),
          wordCount: _nullable(
            _optionalString(
              engine: engine,
              rule: rule.wordCount,
              input: node.value,
              field: 'wordCount',
              warnings: warnings,
            ),
          ),
          latestChapterTitle: _nullable(
            _optionalString(
              engine: engine,
              rule: rule.lastChapter,
              input: node.value,
              field: 'lastChapter',
              warnings: warnings,
            ),
          ),
          time: receivedAt,
          originOrder: source.customOrder,
          sourceScore: source.sourceScore,
          pinned: source.pinned,
        ),
      );
    }
    /// 可变结果用于反转。
    final List<SearchBook> result = unique.values.toList(growable: false);
    return ParsedSearchResult(
      books: reverse ? result.reversed.toList(growable: false) : result,
      warnings: warnings,
    );
  }

  /// 同步解析详情；只在工作 isolate 内调用。
  static ParsedBookInfo _parseBookInfoSync(
    BookSource source,
    Book book,
    String body,
    Uri finalUri,
  ) {
    /// 强类型详情规则。
    final BookInfoSourceRule rule = const BookSourceRuleDecoder().decodeBookInfo(source);
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// `init` 规则后的详情上下文。
    final Object? context = rule.init == null || rule.init?.trim().isEmpty == true
        ? body
        : engine.elements(rule.init, body).firstOrNull?.value ?? body;
    /// 规则解析书名。
    final String parsedName = _cleanName(engine.string(rule.name, context));
    /// 规则解析作者。
    final String parsedAuthor = _cleanAuthor(engine.string(rule.author, context));
    /// 【原生规则容错】详情可选字段的解析告警。
    final List<StandardParseWarning> warnings = <StandardParseWarning>[];
    /// 封面相对地址；失败时沿用搜索结果封面。
    final String cover = _optionalString(
      engine: engine,
      rule: rule.coverUrl,
      input: context,
      field: 'coverUrl',
      warnings: warnings,
    ).trim();
    /// 目录相对地址。
    final String toc = engine.string(rule.tocUrl, context).trim();
    /// Android 以 `canReName` 规则是否非空作为覆盖开关。
    final bool canRename = rule.canReName?.trim().isNotEmpty == true;
    return ParsedBookInfo(
      name: parsedName.isNotEmpty && (canRename || book.name.isEmpty) ? parsedName : book.name,
      author: parsedAuthor.isNotEmpty && (canRename || book.author.isEmpty)
          ? parsedAuthor
          : book.author,
      intro: _nullable(
        _plainText(
          _optionalString(
            engine: engine,
            rule: rule.intro,
            input: context,
            field: 'intro',
            warnings: warnings,
          ),
        ),
        maxLength: 5000,
      ),
      kind: _nullable(
        _optionalStrings(
          engine: engine,
          rule: rule.kind,
          input: context,
          field: 'kind',
          warnings: warnings,
        ).join(','),
        maxLength: 1000,
      ),
      coverUrl: cover.isEmpty ? book.coverUrl : finalUri.resolve(cover).toString(),
      tocUrl: toc.isEmpty ? book.bookUrl : finalUri.resolve(toc).toString(),
      latestChapterTitle: _nullable(
        _optionalString(
          engine: engine,
          rule: rule.lastChapter,
          input: context,
          field: 'lastChapter',
          warnings: warnings,
        ),
      ),
      wordCount: _nullable(
        _optionalString(
          engine: engine,
          rule: rule.wordCount,
          input: context,
          field: 'wordCount',
          warnings: warnings,
        ),
      ),
      warnings: warnings,
    );
  }

  /// 同步解析目录；只在工作 isolate 内调用。
  static ParsedTocPage _parseTocSync(
    BookSource source,
    Book book,
    String body,
    Uri finalUri,
    int startIndex,
  ) {
    /// 强类型目录规则。
    final TocSourceRule rule = const BookSourceRuleDecoder().decodeToc(source);
    _rejectNonEmptyJavaScript(rule.formatJs, '目录 formatJs');
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// 章节节点。
    final List<StandardRuleNode> nodes = engine.elements(rule.chapterList, body).values;
    /// 当前页章节。
    final List<BookChapter> chapters = <BookChapter>[];
    /// 【FLUTTER_REWRITE_DEBUG_LOG】标题规则返回空文本并被跳过的节点数量。
    int skippedEmptyTitleCount = 0;
    /// 【FLUTTER_REWRITE_DEBUG_LOG】章节 URL 规则返回空文本并使用兼容回退的节点数量。
    int fallbackChapterUrlCount = 0;
    for (int offset = 0; offset < nodes.length; offset += 1) {
      /// 当前章节上下文。
      final Object? context = nodes[offset].value;
      /// 标题。
      final String title = engine.string(rule.chapterName, context).trim();
      if (title.isEmpty) {
        skippedEmptyTitleCount += 1;
        continue;
      }
      /// 是否卷标题。
      final bool isVolume = _isTrue(engine.string(rule.isVolume, context));
      /// 章节原始 URL。
      final String rawUrl = engine.string(rule.chapterUrl, context).trim();
      if (rawUrl.isEmpty) {
        fallbackChapterUrlCount += 1;
      }
      /// Android 对空 URL 的兼容回退。
      final String chapterUrl = rawUrl.isEmpty
          ? (isVolume ? '$title${startIndex + offset}' : finalUri.toString())
          : finalUri.resolve(rawUrl).toString();
      chapters.add(
        BookChapter(
          url: chapterUrl,
          title: title,
          bookUrl: book.bookUrl,
          index: startIndex + chapters.length,
          isVolume: isVolume,
          baseUrl: finalUri.toString(),
          isVip: _isTrue(engine.string(rule.isVip, context)),
          isPay: _isTrue(engine.string(rule.isPay, context)),
          tag: _nullable(engine.string(rule.updateTime, context)),
        ),
      );
    }
    /// 下一页目录地址。
    final List<Uri> nextUris = _absoluteUris(
      engine.strings(rule.nextTocUrl, body).values,
      finalUri,
    );
    return ParsedTocPage(
      chapters: chapters,
      nextPageUris: nextUris,
      reverse: rule.chapterList?.startsWith('-') ?? false,
      matchedNodeCount: nodes.length,
      skippedEmptyTitleCount: skippedEmptyTitleCount,
      fallbackChapterUrlCount: fallbackChapterUrlCount,
    );
  }

  /// 同步解析正文；只在工作 isolate 内调用。
  static ParsedContentPage _parseContentSync(
    BookSource source,
    BookChapter chapter,
    String body,
    Uri finalUri,
  ) {
    /// 强类型正文规则。
    final ContentSourceRule rule = const BookSourceRuleDecoder().decodeContent(source);
    _rejectNonEmptyJavaScript(rule.payAction, '正文 payAction');
    /// 普通规则引擎。
    const StandardRuleEngine engine = StandardRuleEngine();
    /// 未格式化正文。
    String content = engine.string(rule.content, body);
    if (rule.replaceRegex?.trim().isNotEmpty == true) {
      content = engine.string(rule.replaceRegex, content);
    }
    /// 格式化后的正文。
    final String formatted = _formatContent(content, finalUri);
    if (!chapter.isVolume && formatted.trim().isEmpty) {
      throw const StandardRuleException('正文规则匹配成功但内容为空');
    }
    return ParsedContentPage(
      content: formatted,
      title: _nullable(engine.string(rule.title, body)),
      subContent: _nullable(engine.string(rule.subContent, body)),
      nextPageUris: _absoluteUris(
        engine.strings(rule.nextContentUrl, body).values,
        finalUri,
      ),
    );
  }

  /// 将相对 URL 列表转成去重绝对地址。
  static List<Uri> _absoluteUris(List<String> values, Uri baseUri) {
    /// 按文本去重的地址。
    final Map<String, Uri> unique = <String, Uri>{};
    for (final String value in values) {
      if (value.trim().isEmpty) {
        continue;
      }
      /// 绝对地址。
      final Uri uri = baseUri.resolve(value.trim());
      unique[uri.toString()] = uri;
    }
    return unique.values.toList(growable: false);
  }

  /// 【原生规则容错】解析单个可选字段，失败时记录告警并返回空文本。
  static String _optionalString({
    required StandardRuleEngine engine,
    required String? rule,
    required Object? input,
    required String field,
    required List<StandardParseWarning> warnings,
  }) {
    try {
      return engine.string(rule, input);
    } on Exception catch (error) {
      warnings.add(StandardParseWarning(field: field, message: error.toString()));
      return '';
    }
  }

  /// 【原生规则容错】解析可选字符串列表，失败时记录告警并返回空列表。
  static List<String> _optionalStrings({
    required StandardRuleEngine engine,
    required String? rule,
    required Object? input,
    required String field,
    required List<StandardParseWarning> warnings,
  }) {
    try {
      return engine.strings(rule, input).values;
    } on Exception catch (error) {
      warnings.add(StandardParseWarning(field: field, message: error.toString()));
      return const <String>[];
    }
  }

  /// 将 URL 转为绝对地址，空值回退到最终响应地址。
  static Uri _absoluteOrFallback(Uri baseUri, String value) {
    return value.isEmpty ? baseUri : baseUri.resolve(value);
  }

  /// 清理常见书名标签。
  static String _cleanName(String value) {
    return value.replaceFirst(RegExp(r'^\s*书名\s*[:：]\s*'), '').trim();
  }

  /// 清理常见作者标签。
  static String _cleanAuthor(String value) {
    return value.replaceFirst(RegExp(r'^\s*作者\s*[:：]\s*'), '').trim();
  }

  /// 将 HTML 简介转成纯文本。
  static String _plainText(String value) {
    return html_parser.parseFragment(value).text?.trim() ?? '';
  }

  /// 将正文 HTML 安全转换为段落文本和受控图片标记，不把脚本或任意标签带入阅读器。
  static String _formatContent(String value, Uri baseUri) {
    if (!RegExp(r'<[A-Za-z!/][^>]*>').hasMatch(value)) {
      return value
          .split(RegExp(r'\r?\n'))
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .join('\n');
    }
    /// 解析后的不可信 HTML 片段。
    final dom.DocumentFragment fragment = html_parser.parseFragment(value);
    /// 输出纯文本、段落换行和图片资源标记的缓冲区。
    final StringBuffer output = StringBuffer();
    for (final dom.Node node in fragment.nodes) {
      _appendReadableNode(node, output, baseUri);
    }
    return output
        .toString()
        .replaceAll(RegExp(r'[\t\f\v]+'), ' ')
        .split(RegExp(r'\r?\n'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .join('\n');
  }

  /// 递归提取可读文本、块级换行、Ruby 注音和 HTTP(S) 图片资源。
  static void _appendReadableNode(
    dom.Node node,
    StringBuffer output,
    Uri baseUri,
  ) {
    if (node is dom.Text) {
      output.write(node.data);
      return;
    }
    if (node is! dom.Element) {
      return;
    }
    /// 当前 HTML 标签的小写名称。
    final String tag = node.localName?.toLowerCase() ?? '';
    if (<String>{'script', 'style', 'noscript', 'template'}.contains(tag)) {
      return;
    }
    if (tag == 'br') {
      output.write('\n');
      return;
    }
    if (tag == 'img') {
      _appendImageMarker(node, output, baseUri);
      return;
    }
    if (tag == 'rt') {
      /// Ruby 注音在纯文本阅读器中使用全角括号保留可读语义。
      final String annotation = node.text.trim();
      if (annotation.isNotEmpty) {
        output.write('（$annotation）');
      }
      return;
    }
    /// 当前标签是否形成独立段落。
    final bool block = <String>{
      'address',
      'article',
      'aside',
      'blockquote',
      'div',
      'figcaption',
      'figure',
      'footer',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'header',
      'li',
      'main',
      'nav',
      'ol',
      'p',
      'pre',
      'section',
      'table',
      'tr',
      'ul',
    }.contains(tag);
    if (block && output.isNotEmpty) {
      output.write('\n');
    }
    for (final dom.Node child in node.nodes) {
      _appendReadableNode(child, output, baseUri);
    }
    if (block) {
      output.write('\n');
    }
  }

  /// 从常见懒加载属性中选择首个安全图片地址并写入资源标记。
  static void _appendImageMarker(
    dom.Element image,
    StringBuffer output,
    Uri baseUri,
  ) {
    /// 书源常见图片与懒加载地址属性候选。
    const List<String> sourceAttributes = <String>[
      'src',
      'data-src',
      'data-original',
      'data-url',
      'data-lazy-src',
    ];
    /// 首个可安全解析的绝对 HTTP(S) 图片地址。
    Uri? uri;
    /// 与图片地址对应且保留 Header 等 JSON 选项的绝对请求规则。
    String requestUrl = '';
    for (final String attribute in sourceAttributes) {
      /// 当前标准或懒加载属性中的不可信地址文本。
      final String candidate = image.attributes[attribute]?.trim() ?? '';
      if (candidate.isEmpty || candidate.length > 16 * 1024) {
        continue;
      }
      try {
        /// 图片 URL 与其 JSON 请求选项的分隔位置。
        final RegExpMatch? optionStart = RegExp(r'\s*,\s*(?=\{)').firstMatch(candidate);
        /// 不包含请求选项的图片地址正文。
        final String urlText = (optionStart == null
                ? candidate
                : candidate.substring(0, optionStart.start))
            .trim();
        /// 基于正文最终响应地址解析的当前绝对图片候选。
        final Uri resolved = baseUri.resolve(urlText);
        if (resolved.host.isNotEmpty &&
            <String>{'http', 'https'}.contains(resolved.scheme.toLowerCase())) {
          uri = resolved;
          /// 只保留可安全进入正文缓存的防盗链类 Header 选项。
          final String options = optionStart == null
              ? ''
              : _safeCachedImageRequestOptions(candidate.substring(optionStart.end));
          requestUrl = '${resolved.toString()}$options';
          break;
        }
      } on FormatException {
        continue;
      }
    }
    /// 图片加载失败时可展示的替代文本。
    final String altText = image.attributes['alt']?.trim() ?? '';
    if (uri == null) {
      if (altText.isNotEmpty) {
        output.write(altText);
      }
      return;
    }
    output
      ..write('\n')
      ..write(
        ReaderContentMarkup.encodeImage(
          uri: uri,
          altText: altText,
          referer: baseUri,
          requestUrl: requestUrl,
        ),
      )
      ..write('\n');
  }

  /// 从图片 URL 选项中保留可重放规则和非凭据 Header，避免 Token/Cookie 进入正文缓存。
  static String _safeCachedImageRequestOptions(String optionJson) {
    try {
      /// 不可信图片 URL JSON 选项。
      final Object? decoded = jsonDecode(optionJson);
      if (decoded is! Map<String, Object?>) {
        return '';
      }
      /// 可以安全持久化并在图片请求时重新执行的 URL 选项；请求 Body 不进入普通缓存。
      const Set<String> replayableOptionNames = <String>{
        'method',
        'charset',
        'retry',
        'js',
        'bodyJs',
        'webView',
        'webJs',
        'webViewDelayTime',
      };
      /// 最终允许进入正文缓存的图片请求选项。
      final Map<String, Object?> safeOptions = <String, Object?>{};
      for (final String name in replayableOptionNames) {
        /// 当前可重放选项的原始值。
        final Object? value = decoded[name];
        if (value == null || value is String || value is num || value is bool) {
          if (value != null) {
            safeOptions[name] = value;
          }
        }
      }
      /// 图片地址选项中的 Header 原值。
      Object? headersValue = decoded['headers'];
      if (headersValue is String) {
        try {
          headersValue = jsonDecode(headersValue);
        } on FormatException {
          headersValue = null;
        }
      }
      /// 允许写入普通正文缓存的非凭据 Header 名。
      const Set<String> allowedHeaderNames = <String>{
        'accept',
        'accept-language',
        'origin',
        'referer',
        'user-agent',
      };
      /// 经过白名单收敛的图片 Header。
      final Map<String, String> safeHeaders = <String, String>{};
      if (headersValue is Map) {
        for (final MapEntry<Object?, Object?> entry in headersValue.entries) {
          /// 当前 Header 名。
          final String name = entry.key?.toString().trim() ?? '';
          /// 当前 Header 值。
          final String value = entry.value?.toString().trim() ?? '';
          if (allowedHeaderNames.contains(name.toLowerCase()) && value.isNotEmpty) {
            safeHeaders[name] = value;
          }
        }
      }
      if (safeHeaders.isNotEmpty) {
        safeOptions['headers'] = safeHeaders;
      }
      if (safeOptions.isEmpty) {
        return '';
      }
      return ',${jsonEncode(safeOptions)}';
    } on FormatException {
      return '';
    }
  }

  /// 将空文本转为 `null`，并限制 Android 对齐字段长度。
  static String? _nullable(String value, {int? maxLength}) {
    /// 去除首尾空白后的值。
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (maxLength != null && trimmed.length > maxLength) {
      return trimmed.substring(0, maxLength);
    }
    return trimmed;
  }

  /// 兼容 Android `isTrue` 的常用布尔文本。
  static bool _isTrue(String value) {
    /// 小写布尔文本。
    final String normalized = value.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'null') {
      return false;
    }
    return normalized != 'false' &&
        normalized != 'no' &&
        normalized != 'not' &&
        normalized != '0' &&
        normalized != '0.0';
  }

  /// 拒绝仍依赖平台 WebView、加密资源或购买动作的非空专属字段。
  static void _rejectNonEmptyJavaScript(String? value, String field) {
    if (value?.trim().isNotEmpty == true) {
      throw StandardRuleException('$field 尚无 Flutter 跨平台兼容实现');
    }
  }
}

/// 通过短周期观察统一 HTTP 令牌，把页面取消同步给 QuickJS 中断处理器。
final class _HttpBackedJsCancellationToken implements JsCancellationToken {
  /// 创建只读取消适配器。
  const _HttpBackedJsCancellationToken(this._httpToken);

  /// 页面或业务协调器持有的统一 HTTP 取消令牌。
  final HttpCancellationToken _httpToken;

  @override
  bool get isCancelled => _httpToken.isCancelled;

  @override
  void Function() addCancellationListener(void Function() listener) {
    if (_httpToken.isCancelled) {
      listener();
      return () {};
    }
    /// 轮询统一令牌的轻量计时器；脚本结束时由返回回调立即释放。
    final Timer timer = Timer.periodic(const Duration(milliseconds: 50), (Timer current) {
      if (_httpToken.isCancelled) {
        current.cancel();
        listener();
      }
    });
    return timer.cancel;
  }
}
