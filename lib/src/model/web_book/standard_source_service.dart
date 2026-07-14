import '../../api/http/http_contract.dart';
import '../../api/http/response_decoder.dart';
import '../../api/http/source_url_resolver.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../analyze_rule/standard_rule_engine.dart';
import 'standard_source_parser.dart';

/// 普通书源四段网络与解析编排入口。
///
/// 本服务不负责跨书源并发，也不直接持久化结果；并发上限与数据库事务由上层 UseCase 管理。
final class StandardBookSourceService {
  /// 创建普通书源服务。
  const StandardBookSourceService(
    this._httpClient,
    this._responseDecoder,
    this._urlResolver,
    this._parser,
  );

  /// 统一 HTTP 客户端。
  final UnifiedHttpClient _httpClient;

  /// 响应字节解码器。
  final HttpResponseDecoder _responseDecoder;

  /// Android URL 普通语法解析器。
  final SourceUrlResolver _urlResolver;

  /// 后台 isolate 规则解析器。
  final StandardBookSourceParser _parser;

  /// 执行搜索 URL 并解析候选书列表。
  Future<List<SearchBook>> search({
    required BookSource source,
    required String keyword,
    required int page,
    required int receivedAt,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 搜索 URL。
    final String? searchUrl = source.searchUrl;
    if (searchUrl == null || searchUrl.trim().isEmpty) {
      throw const StandardRuleException('搜索 URL 不能为空');
    }
    /// 解析后的请求。
    final ResolvedSourceRequest resolved = _urlResolver.resolve(
      rawUrl: searchUrl,
      baseUri: Uri.parse(source.bookSourceUrl),
      source: source,
      keyword: keyword,
      page: page,
    );
    /// 解码响应。
    final DecodedHttpResponse response = await _executeDecoded(
      resolved,
      cancellationToken: cancellationToken,
    );
    return _parser.parseSearch(
      source: source,
      body: response.text,
      finalUri: response.response.finalUri,
      receivedAt: receivedAt,
    );
  }

  /// 请求并解析书籍详情。
  Future<ParsedBookInfo> loadBookInfo({
    required BookSource source,
    required Book book,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 详情请求。
    final ResolvedSourceRequest resolved = _urlResolver.resolve(
      rawUrl: book.bookUrl,
      baseUri: Uri.parse(source.bookSourceUrl),
      source: source,
    );
    /// 解码响应。
    final DecodedHttpResponse response = await _executeDecoded(
      resolved,
      cancellationToken: cancellationToken,
    );
    return _parser.parseBookInfo(
      source: source,
      book: book,
      body: response.text,
      finalUri: response.response.finalUri,
    );
  }

  /// 请求并顺序解析完整目录，检测循环分页并限制最多页数。
  Future<List<BookChapter>> loadToc({
    required BookSource source,
    required Book book,
    HttpCancellationToken? cancellationToken,
    int maxPages = 100,
  }) async {
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
      final ResolvedSourceRequest resolved = _urlResolver.resolve(
        rawUrl: nextUri.toString(),
        baseUri: Uri.parse(source.bookSourceUrl),
        source: source,
      );
      /// 当前目录响应。
      final DecodedHttpResponse response = await _executeDecoded(
        resolved,
        cancellationToken: cancellationToken,
      );
      /// 当前目录页解析结果。
      final ParsedTocPage parsed = await _parser.parseTocPage(
        source: source,
        book: book,
        body: response.text,
        finalUri: response.response.finalUri,
        startIndex: chapters.length,
      );
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
    return List<BookChapter>.unmodifiable(result);
  }

  /// 请求并顺序合并完整章节正文，检测循环分页并限制最多页数。
  Future<ParsedContentPage> loadContent({
    required BookSource source,
    required BookChapter chapter,
    HttpCancellationToken? cancellationToken,
    int maxPages = 100,
  }) async {
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
      final ResolvedSourceRequest resolved = _urlResolver.resolve(
        rawUrl: nextUri.toString(),
        baseUri: Uri.parse(chapter.baseUrl.isEmpty ? source.bookSourceUrl : chapter.baseUrl),
        source: source,
      );
      /// 当前正文响应。
      final DecodedHttpResponse response = await _executeDecoded(
        resolved,
        cancellationToken: cancellationToken,
      );
      /// 当前正文页解析结果。
      final ParsedContentPage parsed = await _parser.parseContentPage(
        source: source,
        chapter: chapter,
        body: response.text,
        finalUri: response.response.finalUri,
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
    return ParsedContentPage(
      content: pages.join('\n'),
      title: title,
      subContent: subContent,
      nextPageUris: const <Uri>[],
    );
  }

  /// 执行带有限重试的请求并解码文本。
  Future<DecodedHttpResponse> _executeDecoded(
    ResolvedSourceRequest resolved, {
    HttpCancellationToken? cancellationToken,
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
        return _responseDecoder.decode(response, ruleCharset: resolved.charset);
      } on UnifiedHttpException catch (error) {
        if (!_canRetry(error.kind) || attempt >= resolved.retryCount) {
          rethrow;
        }
        attempt += 1;
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

/// 为 Iterable 提供不抛异常的首元素读取。
extension _FirstOrNullExtension<T> on Iterable<T> {
  /// 返回首元素，空集合返回 `null`。
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
