import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../api/http/response_decoder.dart';
import '../../api/http/source_url_resolver.dart';
import '../../api/js/script_context.dart';
import '../../api/js/js_engine.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import '../analyze_rule/source_rules.dart';
import '../analyze_rule/legado_javascript_service.dart';
import '../analyze_rule/legado_rule_evaluator.dart';
import '../analyze_rule/standard_rule_engine.dart';
import 'standard_source_parser.dart';

/// 普通书源四段网络与解析编排入口。
///
/// 本服务不负责跨书源并发，也不直接持久化结果；并发上限与数据库事务由上层 UseCase 管理。
final class StandardBookSourceService {
  /// 【FLUTTER_REWRITE_DEBUG_LOG】详细诊断日志统一标识，便于问题解决后完整搜索并移除。
  static const String _debugLogMarker = 'FLUTTER_REWRITE_DEBUG_LOG';

  /// 【FLUTTER_REWRITE_DEBUG_LOG】单段响应日志字符上限，低于 Android Logcat 单条消息限制。
  static const int _debugLogChunkCharacters = 2800;

  /// 创建普通书源服务。
  StandardBookSourceService(
    this._httpClient,
    this._responseDecoder,
    this._urlResolver,
    this._parser,
    LegadoJavaScriptService javaScriptService,
    this._logger,
  ) : _ruleEvaluator = LegadoRuleEvaluator(javaScriptService);

  /// 统一 HTTP 客户端。
  final UnifiedHttpClient _httpClient;

  /// 响应字节解码器。
  final HttpResponseDecoder _responseDecoder;

  /// Android URL 普通语法解析器。
  final SourceUrlResolver _urlResolver;

  /// 后台 isolate 规则解析器。
  final StandardBookSourceParser _parser;

  /// Android `AnalyzeUrl` 对应的普通规则与 JavaScript 混合执行器。
  final LegadoRuleEvaluator _ruleEvaluator;

  /// 【搜书诊断日志】项目统一日志接口，用于记录请求、解码和规则解析阶段。
  final AppLogger _logger;

  /// 执行搜索 URL 并解析候选书列表。
  Future<List<SearchBook>> search({
    required BookSource source,
    required String keyword,
    required int page,
    required int receivedAt,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 【搜书诊断日志】当前书源不可逆标识。
    final String sourceId = appLogDiagnosticId(source.bookSourceUrl);
    /// 【搜书诊断日志】搜索服务阶段耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    /// 搜索 URL。
    final String? searchUrl = source.searchUrl;
    if (searchUrl == null || searchUrl.trim().isEmpty) {
      throw const StandardRuleException('搜索 URL 不能为空');
    }
    /// 解析后的请求。
    final ResolvedSourceRequest resolved = await _resolveRequest(
      rawUrl: searchUrl,
      baseUri: Uri.parse(source.bookSourceUrl),
      source: source,
      keyword: keyword,
      page: page,
      cancellationToken: cancellationToken,
    );
    _logger.debug(
      tag: bookSearchSourceLogTag,
      message: '搜索请求规则已解析 sourceId=$sourceId page=$page '
          'method=${resolved.request.method.name} retryCount=${resolved.retryCount}',
    );
    /// 解码响应。
    final DecodedHttpResponse response = await _executeDecoded(
      resolved,
      cancellationToken: cancellationToken,
      logTag: bookSearchSourceLogTag,
      operation: 'search',
      subjectId: sourceId,
      scriptSource: source,
      keyword: keyword,
      page: page,
    );
    /// 规则解析得到的搜索候选。
    final ParsedSearchResult parsed = await _parser.parseSearch(
      source: source,
      body: response.text,
      finalUri: response.response.finalUri,
      receivedAt: receivedAt,
      keyword: keyword,
      page: page,
      cancellationToken: cancellationToken,
    );
    /// 【原生规则容错日志】可选字段失败不终止当前书源搜索。
    _logParseWarnings(
      parsed.warnings,
      tag: bookSearchSourceLogTag,
      subjectName: 'sourceId',
      subjectId: sourceId,
    );
    _logger.info(
      tag: bookSearchSourceLogTag,
      message: '搜索响应解析完成 sourceId=$sourceId resultCount=${parsed.books.length} '
          'warningCount=${parsed.warnings.length} '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    return parsed.books;
  }

  /// 请求并解析书籍详情。
  Future<ParsedBookInfo> loadBookInfo({
    required BookSource source,
    required Book book,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 【搜书诊断日志】当前书籍不可逆标识。
    final String bookId = appLogDiagnosticId(book.bookUrl);
    /// 【搜书诊断日志】详情服务阶段耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    /// 详情请求。
    final ResolvedSourceRequest resolved = await _resolveRequest(
      rawUrl: book.bookUrl,
      baseUri: Uri.parse(source.bookSourceUrl),
      source: source,
      book: book,
      cancellationToken: cancellationToken,
    );
    /// 解码响应。
    final DecodedHttpResponse response = await _executeDecoded(
      resolved,
      cancellationToken: cancellationToken,
      logTag: bookDetailLogTag,
      operation: 'bookInfo',
      subjectId: bookId,
      scriptSource: source,
      scriptBook: book,
    );
    /// 规则解析得到的详情字段。
    final ParsedBookInfo parsed = await _parser.parseBookInfo(
      source: source,
      book: book,
      body: response.text,
      finalUri: response.response.finalUri,
      cancellationToken: cancellationToken,
    );
    /// 【原生规则容错日志】可选字段失败不阻断详情、目录和阅读链路。
    _logParseWarnings(
      parsed.warnings,
      tag: bookDetailLogTag,
      subjectName: 'bookId',
      subjectId: bookId,
    );
    _logger.info(
      tag: bookDetailLogTag,
      message: '详情响应解析完成 bookId=$bookId hasTocUrl=${parsed.tocUrl?.isNotEmpty == true} '
          'hasCover=${parsed.coverUrl?.isNotEmpty == true} warningCount=${parsed.warnings.length} '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    return parsed;
  }

  /// 【原生规则容错日志】通过项目统一日志系统输出后台 isolate 返回的字段告警。
  void _logParseWarnings(
    List<StandardParseWarning> warnings, {
    required String tag,
    required String subjectName,
    required String subjectId,
  }) {
    /// 【搜书诊断日志】同一书源内按字段和原因去重，避免每个搜索结果重复输出相同告警。
    final Set<String> emittedWarnings = <String>{};
    for (final StandardParseWarning warning in warnings) {
      /// 【搜书诊断日志】不包含正文的稳定告警去重键。
      final String warningKey = '${warning.field}\u0000${warning.message}';
      if (!emittedWarnings.add(warningKey)) {
        continue;
      }
      /// 【FLUTTER_JS_COMPAT_LOG】当前可恢复字段对应的结构化 JavaScript 异常。
      final JsEngineException? javaScriptError = warning.javaScriptError;
      if (javaScriptError != null) {
        /// 【FLUTTER_JS_COMPAT_LOG】QuickJS 原始摘要经过认证值、长文本和查询参数脱敏。
        final String engineDetail = appLogSafeJavaScriptDiagnostic(
          javaScriptError.stack ?? javaScriptError.message,
        );
        /// 【FLUTTER_JS_COMPAT_LOG】只包含宿主桥方法名和参数类型的调用轨迹。
        final String bridgeCalls = javaScriptError.bridgeCalls.isEmpty
            ? '<none>'
            : javaScriptError.bridgeCalls.join(' > ');
        _logger.warning(
          tag: tag,
          message: '$javaScriptCompatibilityDebugLogMarker JavaScript 可选字段失败但流程继续 '
              '$subjectName=$subjectId field=${warning.field} kind=${javaScriptError.kind.name} '
              'scriptName=${appLogSafeLabel(javaScriptError.scriptName ?? "<unknown>", maximumLength: 120)} '
              'line=${javaScriptError.line?.toString() ?? "<null>"} '
              'column=${javaScriptError.column?.toString() ?? "<null>"} '
              'bridgeCalls=$bridgeCalls engineDetail=$engineDetail',
        );
      }
      _logger.warning(
        tag: tag,
        message: '可选字段解析失败但流程继续 $subjectName=$subjectId '
            'field=${warning.field} reason=${appLogSafeLabel(warning.message)}',
      );
    }
  }

  /// 请求并顺序解析完整目录，检测循环分页并限制最多页数。
  Future<List<BookChapter>> loadToc({
    required BookSource source,
    required Book book,
    HttpCancellationToken? cancellationToken,
    int maxPages = 100,
  }) async {
    /// 【搜书诊断日志】当前书籍不可逆标识。
    final String bookId = appLogDiagnosticId(book.bookUrl);
    /// 【搜书诊断日志】完整目录加载耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(tag: bookTocLogTag, message: '目录分页加载开始 bookId=$bookId maxPages=$maxPages');
    // FLUTTER_REWRITE_DEBUG_LOG：输出本次目录请求使用的书源身份、地址关系和完整目录规则。
    _logTocRuleDiagnostics(source: source, book: book, bookId: bookId);
    /// 首个目录地址；空值回退详情地址。
    Uri nextUri = Uri.parse(book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl);
    /// 已访问地址，防止规则产生分页环。
    final Set<String> visited = <String>{};
    /// 按章节地址去重的章节。
    final Map<String, BookChapter> chapters = <String, BookChapter>{};
    /// Android 目录列表规则的反序标识，由首个目录页确定。
    bool reverse = false;
    while (visited.length < maxPages && !visited.contains(nextUri.toString())) {
      visited.add(nextUri.toString());
      /// 当前目录请求。
      final ResolvedSourceRequest resolved = await _resolveRequest(
        rawUrl: nextUri.toString(),
        baseUri: Uri.parse(source.bookSourceUrl),
        source: source,
        book: book,
        cancellationToken: cancellationToken,
      );
      // FLUTTER_REWRITE_DEBUG_LOG：记录目录请求地址、方法和非敏感请求结构，不输出 Header 值或请求正文。
      _logger.debug(
        tag: bookTocLogTag,
        message: '$_debugLogMarker 目录请求准备 bookId=$bookId page=${visited.length} '
            'requestUri=${_sanitizeDiagnosticText(resolved.request.uri.toString())} '
            'method=${resolved.request.method.name} bodyType=${resolved.request.body.runtimeType} '
            'headerNames=${resolved.request.headers.keys.join(',')} '
            'cookieMode=${resolved.request.cookieMode.name} retryCount=${resolved.retryCount}',
      );
      /// 当前目录响应。
      final DecodedHttpResponse response = await _executeDecoded(
        resolved,
        cancellationToken: cancellationToken,
        logTag: bookTocLogTag,
        operation: 'tocPage',
        subjectId: bookId,
        scriptSource: source,
        scriptBook: book,
      );
      /// 当前目录页解析结果；`late final` 仅用于在异常路径先输出本页完整诊断数据。
      late final ParsedTocPage parsed;
      try {
        parsed = await _parser.parseTocPage(
          source: source,
          book: book,
          body: response.text,
          finalUri: response.response.finalUri,
          startIndex: chapters.length,
          cancellationToken: cancellationToken,
        );
      } catch (error) {
        // FLUTTER_REWRITE_DEBUG_LOG：规则抛错时也保留脱敏后的完整响应，避免只有异常类型没有输入数据。
        _logger.error(
          tag: bookTocLogTag,
          message: '$_debugLogMarker 目录规则解析抛错 bookId=$bookId page=${visited.length} '
              'errorType=${error.runtimeType}',
        );
        _logTocResponseDiagnostics(
          bookId: bookId,
          page: visited.length,
          reason: 'parserException',
          response: response,
        );
        rethrow;
      }
      /// 【搜书诊断日志】记录每页解析规模，便于定位分页循环或空页。
      _logger.debug(
        tag: bookTocLogTag,
        message: '$_debugLogMarker 目录页解析完成 bookId=$bookId page=${visited.length} '
            'pageChapterCount=${parsed.chapters.length} nextPageCount=${parsed.nextPageUris.length} '
            'accumulatedCount=${chapters.length} matchedNodeCount=${parsed.matchedNodeCount} '
            'skippedEmptyTitleCount=${parsed.skippedEmptyTitleCount} '
            'fallbackChapterUrlCount=${parsed.fallbackChapterUrlCount}',
      );
      if (parsed.chapters.isEmpty) {
        // FLUTTER_REWRITE_DEBUG_LOG：空目录页是当前问题的关键失败点，此时输出脱敏后的完整响应正文。
        _logTocResponseDiagnostics(
          bookId: bookId,
          page: visited.length,
          reason: 'emptyChapterPage',
          response: response,
        );
      }
      if (visited.length == 1) {
        reverse = parsed.reverse;
      }
      for (final BookChapter chapter in parsed.chapters) {
        chapters.putIfAbsent(chapter.url, () => chapter);
      }
      /// 尚未访问的下一页。
      final Uri? candidate = parsed.nextPageUris
          .where((Uri uri) => !visited.contains(uri.toString()))
          .firstOrNull;
      if (candidate == null) {
        break;
      }
      nextUri = candidate;
    }
    if (chapters.isEmpty) {
      _logger.warning(
        tag: bookTocLogTag,
        message: '目录分页结束但无章节 bookId=$bookId pageCount=${visited.length} '
            'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      throw const StandardRuleException('目录规则合法但章节列表为空');
    }
    /// 根据 Android `chapterList` 的 `-` 前缀得到最终显示顺序。
    final Iterable<BookChapter> orderedChapters = reverse
        ? chapters.values.toList(growable: false).reversed
        : chapters.values;
    /// 重新生成连续索引的结果。
    final List<BookChapter> result = <BookChapter>[];
    for (final BookChapter chapter in orderedChapters) {
      result.add(_copyChapterWithIndex(chapter, result.length));
    }
    /// 不可变完整目录。
    final List<BookChapter> immutableResult = List<BookChapter>.unmodifiable(result);
    _logger.info(
      tag: bookTocLogTag,
      message: '目录分页加载完成 bookId=$bookId pageCount=${visited.length} '
          'chapterCount=${immutableResult.length} reverse=$reverse '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    return immutableResult;
  }

  /// 请求并顺序合并完整章节正文，检测循环分页并限制最多页数。
  Future<ParsedContentPage> loadContent({
    required BookSource source,
    required BookChapter chapter,
    HttpCancellationToken? cancellationToken,
    int maxPages = 100,
  }) async {
    /// 【搜书诊断日志】当前章节不可逆标识。
    final String chapterId = appLogDiagnosticId(chapter.url);
    /// 【搜书诊断日志】章节正文网络管线耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '章节正文分页加载开始 chapterId=$chapterId maxPages=$maxPages',
    );
    /// 首个正文地址。
    Uri nextUri = Uri.parse(chapter.url);
    /// 已访问地址。
    final Set<String> visited = <String>{};
    /// 每页正文。
    final List<String> pages = <String>[];
    /// 首个非空标题。
    String? title;
    /// 首个非空副正文。
    String? subContent;
    while (visited.length < maxPages && !visited.contains(nextUri.toString())) {
      visited.add(nextUri.toString());
      /// 当前正文请求。
      final ResolvedSourceRequest resolved = await _resolveRequest(
        rawUrl: nextUri.toString(),
        baseUri: Uri.parse(chapter.baseUrl.isEmpty ? source.bookSourceUrl : chapter.baseUrl),
        source: source,
        chapter: chapter,
        cancellationToken: cancellationToken,
      );
      /// 当前正文响应。
      final DecodedHttpResponse response = await _executeDecoded(
        resolved,
        cancellationToken: cancellationToken,
        logTag: bookReaderContentLogTag,
        operation: 'contentPage',
        subjectId: chapterId,
        scriptSource: source,
        scriptChapter: chapter,
      );
      /// 当前正文页解析结果。
      final ParsedContentPage parsed = await _parser.parseContentPage(
        source: source,
        chapter: chapter,
        body: response.text,
        finalUri: response.response.finalUri,
        cancellationToken: cancellationToken,
      );
      /// 【搜书诊断日志】只记录正文长度，不写入正文内容。
      _logger.debug(
        tag: bookReaderContentLogTag,
        message: '章节正文页解析完成 chapterId=$chapterId page=${visited.length} '
            'contentLength=${parsed.content.length} nextPageCount=${parsed.nextPageUris.length}',
      );
      pages.add(parsed.content);
      title ??= parsed.title;
      subContent ??= parsed.subContent;
      /// 尚未访问的下一页。
      final Uri? candidate = parsed.nextPageUris
          .where((Uri uri) => !visited.contains(uri.toString()))
          .firstOrNull;
      if (candidate == null) {
        break;
      }
      nextUri = candidate;
    }
    /// 合并后的正文页结果。
    final ParsedContentPage result = ParsedContentPage(
      content: pages.join('\n'),
      title: title,
      subContent: subContent,
      nextPageUris: const <Uri>[],
    );
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '章节正文分页加载完成 chapterId=$chapterId pageCount=${visited.length} '
          'contentLength=${result.content.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    return result;
  }

  /// 【FLUTTER_REWRITE_DEBUG_LOG】输出目录入口使用的书源、地址关系和规则全文。
  void _logTocRuleDiagnostics({
    required BookSource source,
    required Book book,
    required String bookId,
  }) {
    /// 【FLUTTER_REWRITE_DEBUG_LOG】去除换行并限制长度后的书源显示名称。
    final String safeSourceName = appLogSafeLabel(
      _sanitizeDiagnosticText(source.bookSourceName),
      maximumLength: 200,
    );
    _logger.debug(
      tag: bookTocLogTag,
      message: '$_debugLogMarker 目录诊断上下文 bookId=$bookId sourceName=$safeSourceName '
          'sourceId=${appLogDiagnosticId(source.bookSourceUrl)} '
          'sourceUrl=${_sanitizeDiagnosticText(source.bookSourceUrl)} '
          'bookUrl=${_sanitizeDiagnosticText(book.bookUrl)} '
          'tocUrl=${_sanitizeDiagnosticText(book.tocUrl)} '
          'tocEqualsBookUrl=${book.tocUrl == book.bookUrl}',
    );
    try {
      /// 【FLUTTER_REWRITE_DEBUG_LOG】用于读取详情目录地址规则和目录各字段规则的强类型解码器。
      const BookSourceRuleDecoder decoder = BookSourceRuleDecoder();
      /// 【FLUTTER_REWRITE_DEBUG_LOG】详情规则，仅提取决定目录地址的 `tocUrl` 字段。
      final BookInfoSourceRule bookInfoRule = decoder.decodeBookInfo(source);
      /// 【FLUTTER_REWRITE_DEBUG_LOG】当前书源的全部目录规则字段。
      final TocSourceRule tocRule = decoder.decodeToc(source);
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleBookInfo.tocUrl',
        value: bookInfoRule.tocUrl ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.chapterList',
        value: tocRule.chapterList ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.chapterName',
        value: tocRule.chapterName ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.chapterUrl',
        value: tocRule.chapterUrl ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.isVolume',
        value: tocRule.isVolume ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.isVip',
        value: tocRule.isVip ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.isPay',
        value: tocRule.isPay ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.updateTime',
        value: tocRule.updateTime ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.nextTocUrl',
        value: tocRule.nextTocUrl ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.preUpdateJs',
        value: tocRule.preUpdateJs ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.formatJs',
        value: tocRule.formatJs ?? '<null>',
      );
      _logDiagnosticChunks(
        bookId: bookId,
        label: 'ruleToc.rawJson',
        value: source.ruleToc ?? '<null>',
      );
    } catch (error) {
      // FLUTTER_REWRITE_DEBUG_LOG：日志解码失败不能改变原目录加载流程，只记录类型并继续。
      _logger.warning(
        tag: bookTocLogTag,
        message: '$_debugLogMarker 目录规则诊断解码失败 bookId=$bookId '
            'errorType=${error.runtimeType}',
      );
    }
  }

  /// 【FLUTTER_REWRITE_DEBUG_LOG】输出目录失败页面的响应元数据和脱敏后的完整正文。
  void _logTocResponseDiagnostics({
    required String bookId,
    required int page,
    required String reason,
    required DecodedHttpResponse response,
  }) {
    /// 【FLUTTER_REWRITE_DEBUG_LOG】保留请求地址、重定向地址、Header 名称和原始字节的 HTTP 响应。
    final HttpResponse rawResponse = response.response;
    /// 【FLUTTER_REWRITE_DEBUG_LOG】排序后的响应 Header 名称；不记录任何 Header 值。
    final List<String> headerNames = rawResponse.headers.keys.toList(growable: false)..sort();
    /// 【FLUTTER_REWRITE_DEBUG_LOG】响应中 `Set-Cookie` 条目数量，只记录数量不记录 Cookie 内容。
    final int setCookieCount = rawResponse.headers['set-cookie']?.length ?? 0;
    /// 【FLUTTER_REWRITE_DEBUG_LOG】重定向 Location；输出前统一脱敏。
    final String safeLocation = _sanitizeDiagnosticText(
      rawResponse.firstHeader('location') ?? '<null>',
    );
    _logger.debug(
      tag: bookTocLogTag,
      message: '$_debugLogMarker 目录响应诊断开始 bookId=$bookId page=$page reason=$reason '
          'requestUri=${_sanitizeDiagnosticText(rawResponse.requestUri.toString())} '
          'finalUri=${_sanitizeDiagnosticText(rawResponse.finalUri.toString())} '
          'redirected=${rawResponse.requestUri != rawResponse.finalUri} '
          'status=${rawResponse.statusCode} charset=${response.charset} '
          'byteCount=${rawResponse.bytes.length} characterCount=${response.text.length} '
          'contentType=${_sanitizeDiagnosticText(rawResponse.firstHeader('content-type') ?? '<null>')} '
          'contentEncoding=${_sanitizeDiagnosticText(rawResponse.firstHeader('content-encoding') ?? '<null>')} '
          'location=$safeLocation setCookieCount=$setCookieCount '
          'headerNames=${headerNames.join(',')}',
    );
    _logDiagnosticChunks(
      bookId: bookId,
      label: 'tocResponseBody',
      value: response.text,
    );
    _logger.debug(
      tag: bookTocLogTag,
      message: '$_debugLogMarker 目录响应诊断结束 bookId=$bookId page=$page reason=$reason',
    );
  }

  /// 【FLUTTER_REWRITE_DEBUG_LOG】将规则或响应正文脱敏、转义换行并按 Logcat 安全长度逐段输出。
  void _logDiagnosticChunks({
    required String bookId,
    required String label,
    required String value,
  }) {
    /// 【FLUTTER_REWRITE_DEBUG_LOG】移除敏感字段后的日志文本。
    final String sanitized = _sanitizeDiagnosticText(value);
    /// 【FLUTTER_REWRITE_DEBUG_LOG】把真实换行和制表符显示为转义文本，避免 Logcat 产生无 Tag 空行。
    final String escaped = sanitized
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t');
    if (escaped.isEmpty) {
      _logger.debug(
        tag: bookTocLogTag,
        message: '$_debugLogMarker $label bookId=$bookId chunk=1/1 data=<empty>',
      );
      return;
    }
    /// 【FLUTTER_REWRITE_DEBUG_LOG】完整文本按固定字符上限拆分后的总段数。
    final int chunkCount = (escaped.length + _debugLogChunkCharacters - 1) ~/
        _debugLogChunkCharacters;
    // FLUTTER_REWRITE_DEBUG_LOG：`chunkIndex` 表示当前按原始顺序输出的分段序号。
    for (int chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      /// 【FLUTTER_REWRITE_DEBUG_LOG】当前分段在完整文本中的起始字符位置。
      final int start = chunkIndex * _debugLogChunkCharacters;
      /// 【FLUTTER_REWRITE_DEBUG_LOG】当前分段在完整文本中的结束字符位置。
      final int candidateEnd = start + _debugLogChunkCharacters;
      /// 【FLUTTER_REWRITE_DEBUG_LOG】不超过完整文本长度的实际结束位置。
      final int end = candidateEnd < escaped.length ? candidateEnd : escaped.length;
      /// 【FLUTTER_REWRITE_DEBUG_LOG】当前准备写入 Logcat 和日志文件的文本分段。
      final String chunk = escaped.substring(start, end);
      _logger.debug(
        tag: bookTocLogTag,
        message: '$_debugLogMarker $label bookId=$bookId '
            'chunk=${chunkIndex + 1}/$chunkCount range=$start:$end data=$chunk',
      );
    }
  }

  /// 【FLUTTER_REWRITE_DEBUG_LOG】移除规则、URL 或 HTML 中可能出现的认证与账号敏感值。
  String _sanitizeDiagnosticText(String value) {
    /// 【FLUTTER_REWRITE_DEBUG_LOG】持续承接每一轮脱敏结果的可变文本。
    String sanitized = value;
    /// 【FLUTTER_REWRITE_DEBUG_LOG】密码输入框可能同时包含名称和值，整段替换避免字段顺序造成遗漏。
    final RegExp passwordInputPattern = RegExp(
      r'''<input\b[^>]*(?:type\s*=\s*["']?password|name\s*=\s*["']?(?:password|passwd|secret))[^>]*>''',
      caseSensitive: false,
      dotAll: true,
    );
    sanitized = sanitized.replaceAll(passwordInputPattern, '<input [REDACTED]>');
    /// 【FLUTTER_REWRITE_DEBUG_LOG】带引号的认证、Cookie、Token、密码和密钥字段。
    final RegExp quotedSensitiveValuePattern = RegExp(
      r'''((?:["']?)(?:authorization|proxy-authorization|cookie|set-cookie|access[_-]?token|refresh[_-]?token|csrf[_-]?token|token|password|passwd|secret|api[_-]?key|session[_-]?id)(?:["']?)\s*[:=]\s*)(["'])(.*?)\2''',
      caseSensitive: false,
      dotAll: true,
    );
    sanitized = sanitized.replaceAllMapped(quotedSensitiveValuePattern, (Match match) {
      /// 【FLUTTER_REWRITE_DEBUG_LOG】敏感字段名及其赋值分隔符。
      final String prefix = match.group(1) ?? '';
      /// 【FLUTTER_REWRITE_DEBUG_LOG】原敏感值使用的引号，保留后避免破坏 HTML/JSON 结构。
      final String quote = match.group(2) ?? '"';
      return '$prefix$quote[REDACTED]$quote';
    });
    /// 【FLUTTER_REWRITE_DEBUG_LOG】URL 查询参数等未加引号的敏感字段值。
    final RegExp unquotedSensitiveValuePattern = RegExp(
      r'''((?:["']?)(?:authorization|proxy-authorization|cookie|set-cookie|access[_-]?token|refresh[_-]?token|csrf[_-]?token|token|password|passwd|secret|api[_-]?key|session[_-]?id)(?:["']?)\s*[:=]\s*)([^"'\s&;,<>]+)''',
      caseSensitive: false,
    );
    sanitized = sanitized.replaceAllMapped(unquotedSensitiveValuePattern, (Match match) {
      /// 【FLUTTER_REWRITE_DEBUG_LOG】未加引号敏感字段名及其赋值分隔符。
      final String prefix = match.group(1) ?? '';
      return '${prefix}[REDACTED]';
    });
    /// 【FLUTTER_REWRITE_DEBUG_LOG】没有显式字段名但带认证方案前缀的凭据。
    final RegExp authorizationSchemePattern = RegExp(
      r'''\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+''',
      caseSensitive: false,
    );
    sanitized = sanitized.replaceAll(authorizationSchemePattern, '[AUTHORIZATION_REDACTED]');
    /// 【FLUTTER_REWRITE_DEBUG_LOG】页面脚本中可能直接出现、未带字段名的 JWT。
    final RegExp jwtPattern = RegExp(
      r'''\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b''',
    );
    return sanitized.replaceAll(jwtPattern, '[JWT_REDACTED]');
  }

  /// 对齐 Android `AnalyzeUrl`：先执行 URL/Header 脚本，再交给 M3 请求解析器。
  Future<ResolvedSourceRequest> _resolveRequest({
    required String rawUrl,
    required Uri baseUri,
    required BookSource source,
    String? keyword,
    int? page,
    Book? book,
    BookChapter? chapter,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 同时观察统一 HTTP 取消状态的脚本取消令牌。
    final JsCancellationToken? jsCancellationToken = cancellationToken == null
        ? null
        : _ServiceHttpBackedJsCancellationToken(cancellationToken);
    /// 当前 URL 与 Header 脚本共享的 Legado 上下文。
    final LegadoScriptContext scriptContext = LegadoScriptContext(
      source: source,
      baseUri: baseUri,
      book: book,
      chapter: chapter,
      result: rawUrl,
      key: keyword,
      page: page,
      httpCancellationToken: cancellationToken,
    );
    /// 已执行脚本的 URL 规则；普通 `{{key}}/{{page}}` 仍由 M3 快路径替换。
    final String resolvedUrl = _urlRequiresJavaScript(rawUrl)
        ? await _ruleEvaluator.string(
            rule: rawUrl,
            input: rawUrl,
            context: scriptContext,
            cancellationToken: jsCancellationToken,
          )
        : rawUrl;
    // `{{key}}` 与 `{{page}}` 是 SourceUrlResolver 负责替换的内建占位符，
    // 这里只拦截执行后仍残留的真正 JavaScript，避免普通书源在发起请求前被误判失败。
    if (_urlRequiresJavaScript(resolvedUrl)) {
      /// 【FLUTTER_JS_COMPAT_LOG】执行后仍残留的固定脚本标记，不包含 URL 或脚本正文。
      final String unresolvedMarkers = _javaScriptMarkerSummary(resolvedUrl);
      throw JsEngineException(
        kind: JsFailureKind.syntax,
        message: 'URL JavaScript 执行后仍包含未解析标记',
        scriptName: '${source.bookSourceName}/url-resolution',
        stack: 'unresolvedMarkers=$unresolvedMarkers',
        bridgeCalls: List<String>.unmodifiable(scriptContext.bridgeCalls),
      );
    }
    /// Android URL 选项中的请求前 `js` 与响应后 `bodyJs`。
    final SourceUrlJavaScriptOptions scriptOptions = _urlResolver.readJavaScriptOptions(
      rawUrl: resolvedUrl,
      keyword: keyword,
      page: page,
    );
    /// 不含选项的绝对 URL，作为 Android `UrlOption.js` 的 `result`。
    final String absoluteOptionUrl = baseUri.resolve(scriptOptions.urlText).toString();
    /// Android 会在执行 `UrlOption.js` 前把 `baseUrl` 更新为当前绝对 URL。
    final LegadoScriptContext optionScriptContext = LegadoScriptContext(
      source: source,
      baseUri: Uri.parse(absoluteOptionUrl),
      book: book,
      chapter: chapter,
      result: absoluteOptionUrl,
      key: keyword,
      page: page,
      variables: scriptContext.variables,
      bridgeCalls: scriptContext.bridgeCalls,
      httpCancellationToken: cancellationToken,
    );
    /// `UrlOption.js` 执行后的最终请求 URL。
    final String? evaluatedOptionUrl = scriptOptions.urlJavaScript?.trim().isNotEmpty == true
        ? await _ruleEvaluator.string(
            rule: '@js:${scriptOptions.urlJavaScript}',
            input: absoluteOptionUrl,
            context: optionScriptContext,
            cancellationToken: jsCancellationToken,
          )
        : null;
    /// 已执行脚本的书源 Header；无脚本时保留原始值。
    final String? sourceHeader = source.header;
    final String? resolvedHeader = _ruleEvaluator.containsJavaScript(sourceHeader)
        ? await _ruleEvaluator.string(
            rule: sourceHeader,
            input: sourceHeader,
            context: scriptContext,
            cancellationToken: jsCancellationToken,
          )
        : sourceHeader;
    return _urlResolver.resolve(
      rawUrl: resolvedUrl,
      baseUri: baseUri,
      source: source,
      keyword: keyword,
      page: page,
      header: resolvedHeader,
      evaluatedOptionUrl: evaluatedOptionUrl,
      javaScriptOptionsEvaluated:
          scriptOptions.urlJavaScript?.trim().isNotEmpty == true ||
          scriptOptions.bodyJavaScript?.trim().isNotEmpty == true,
    );
  }

  /// 判断 URL 是否包含超出 M3 内建关键字和页码替换能力的脚本。
  bool _urlRequiresJavaScript(String rawUrl) {
    /// 去除 M3 已原生支持占位符后的 URL。
    /// URL 选项起点；选项中的 `js/bodyJs` 由专属 Android 顺序处理。
    final RegExpMatch? optionStart = RegExp(r'\s*,\s*(?=\{)').firstMatch(rawUrl);
    /// 不包含 URL JSON 选项的规则文本。
    final String urlRule = optionStart == null ? rawUrl : rawUrl.substring(0, optionStart.start);
    final String withoutBuiltIns = urlRule
        .replaceAll('{{key}}', '')
        .replaceAll('{{page}}', '');
    return _ruleEvaluator.containsJavaScript(withoutBuiltIns);
  }

  /// 【FLUTTER_JS_COMPAT_LOG】汇总 URL 中残留的固定 JavaScript 标记，不记录 URL 或表达式内容。
  String _javaScriptMarkerSummary(String value) {
    /// 【FLUTTER_JS_COMPAT_LOG】移除后续 URL 解析器仍需处理的内建占位符，避免诊断信息误报。
    final String withoutBuiltIns = value
        .replaceAll('{{key}}', '')
        .replaceAll('{{page}}', '');
    /// 【FLUTTER_JS_COMPAT_LOG】小写规则仅用于大小写不敏感的标记判断。
    final String normalized = withoutBuiltIns.toLowerCase();
    /// 【FLUTTER_JS_COMPAT_LOG】当前残留标记名称列表。
    final List<String> markers = <String>[
      if (normalized.contains('@js:')) '@js',
      if (normalized.contains('<js>')) '<js>',
      if (normalized.contains('</js>')) '</js>',
      if (withoutBuiltIns.contains('{{')) '{{',
      if (withoutBuiltIns.contains('}}')) '}}',
    ];
    return markers.isEmpty ? '<unknown>' : markers.join(',');
  }

  /// 执行带有限重试的请求并解码文本。
  Future<DecodedHttpResponse> _executeDecoded(
    ResolvedSourceRequest resolved, {
    HttpCancellationToken? cancellationToken,
    required String logTag,
    required String operation,
    required String subjectId,
    BookSource? scriptSource,
    Book? scriptBook,
    BookChapter? scriptChapter,
    String? keyword,
    int? page,
  }) async {
    /// 当前尝试序号。
    int attempt = 0;
    while (true) {
      try {
        /// 原始响应。
        final HttpResponse response = await _httpClient.execute(
          resolved.request,
          cancellationToken: cancellationToken,
        );
        /// 解码后的响应。
        final DecodedHttpResponse decoded = _responseDecoder.decode(
          response,
          ruleCharset: resolved.charset,
        );
        /// Android URL 选项中的响应正文脚本。
        final String? bodyJavaScript = resolved.bodyJavaScript;
        if (bodyJavaScript?.trim().isNotEmpty == true && scriptSource != null) {
          /// 同时观察统一 HTTP 取消状态的脚本取消令牌。
          final JsCancellationToken? jsCancellationToken = cancellationToken == null
              ? null
              : _ServiceHttpBackedJsCancellationToken(cancellationToken);
          /// `bodyJs` 使用最终响应地址和解码正文创建独立脚本上下文。
          final LegadoScriptContext bodyContext = LegadoScriptContext(
            source: scriptSource,
            baseUri: response.finalUri,
            book: scriptBook,
            chapter: scriptChapter,
            result: decoded.text,
            key: keyword,
            page: page,
            httpCancellationToken: cancellationToken,
          );
          /// `bodyJs` 执行后的响应正文。
          final String transformedBody = await _ruleEvaluator.string(
            rule: '@js:$bodyJavaScript',
            input: decoded.text,
            context: bodyContext,
            cancellationToken: jsCancellationToken,
          );
          return DecodedHttpResponse(
            text: transformedBody,
            charset: decoded.charset,
            response: decoded.response,
          );
        }
        _logger.debug(
          tag: logTag,
          message: 'HTTP 响应已解码 operation=$operation subjectId=$subjectId '
              'status=${response.statusCode} byteCount=${response.bytes.length} '
              'charset=${decoded.charset} attempt=${attempt + 1}',
        );
        return decoded;
      } on UnifiedHttpException catch (error) {
        if (!_canRetry(error.kind) || attempt >= resolved.retryCount) {
          rethrow;
        }
        attempt += 1;
        /// 【搜书诊断日志】记录有限重试的分类和序号，不记录请求地址或请求体。
        _logger.warning(
          tag: logTag,
          message: 'HTTP 请求准备重试 operation=$operation subjectId=$subjectId '
              'failureKind=${error.kind.name} nextAttempt=${attempt + 1}/${resolved.retryCount + 1}',
          error: error,
        );
      }
    }
  }

  /// 判断网络错误是否适合立即重试。
  bool _canRetry(HttpFailureKind kind) {
    return kind == HttpFailureKind.dns ||
        kind == HttpFailureKind.connection ||
        kind == HttpFailureKind.connectTimeout ||
        kind == HttpFailureKind.sendTimeout ||
        kind == HttpFailureKind.receiveTimeout ||
        kind == HttpFailureKind.totalTimeout;
  }

  /// 复制章节并替换索引。
  BookChapter _copyChapterWithIndex(BookChapter chapter, int index) {
    return BookChapter(
      url: chapter.url,
      title: chapter.title,
      bookUrl: chapter.bookUrl,
      index: index,
      isVolume: chapter.isVolume,
      baseUrl: chapter.baseUrl,
      isVip: chapter.isVip,
      isPay: chapter.isPay,
      resourceUrl: chapter.resourceUrl,
      tag: chapter.tag,
      wordCount: chapter.wordCount,
      start: chapter.start,
      end: chapter.end,
      startFragmentId: chapter.startFragmentId,
      endFragmentId: chapter.endFragmentId,
      variable: chapter.variable,
      reviewImg: chapter.reviewImg,
    );
  }
}

/// 通过短周期观察统一 HTTP 令牌，把业务取消同步给 URL/Header QuickJS 执行。
final class _ServiceHttpBackedJsCancellationToken implements JsCancellationToken {
  /// 创建只读取消适配器。
  const _ServiceHttpBackedJsCancellationToken(this._httpToken);

  /// 搜索、详情或阅读协调器持有的统一 HTTP 取消令牌。
  final HttpCancellationToken _httpToken;

  @override
  bool get isCancelled => _httpToken.isCancelled;

  @override
  void Function() addCancellationListener(void Function() listener) {
    if (_httpToken.isCancelled) {
      listener();
      return () {};
    }
    /// 脚本执行期间观察取消状态的轻量计时器。
    final Timer timer = Timer.periodic(const Duration(milliseconds: 50), (Timer current) {
      if (_httpToken.isCancelled) {
        current.cancel();
        listener();
      }
    });
    return timer.cancel;
  }
}

/// 为 Iterable 提供不抛异常的首元素读取。
extension _FirstOrNullExtension<T> on Iterable<T> {
  /// 返回首元素，空集合返回 `null`。
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
