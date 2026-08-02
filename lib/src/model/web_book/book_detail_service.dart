import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import 'standard_source_parser.dart';
import 'standard_source_service.dart';

/// 表示详情解析后可继续加载目录和加入书架的完整上下文。
final class BookDetailSnapshot {
  /// 创建不可变详情快照。
  const BookDetailSnapshot({required this.source, required this.book});

  /// 当前详情对应书源，后续换源可替换而不绑定唯一实现。
  final BookSource source;

  /// 合并搜索结果和详情字段后的书籍。
  final Book book;
}

/// 表示书架刷新得到的书籍事实和完整目录。
final class RefreshedBookResult {
  /// 创建不可变刷新结果。
  RefreshedBookResult({
    required this.book,
    required List<BookChapter> chapters,
    required this.anchorPageUrl,
    required List<String> visitedPageUrls,
    required this.reverse,
    required this.pageCount,
  }) : chapters = List<BookChapter>.unmodifiable(chapters),
       visitedPageUrls = List<String>.unmodifiable(visitedPageUrls);

  /// 已更新目录统计的书籍。
  final Book book;

  /// 完整目录。
  final List<BookChapter> chapters;

  /// 下次增量更新应访问的目录分页锚点。
  final String anchorPageUrl;

  /// 本次刷新后已确认的分页地址集合。
  final List<String> visitedPageUrls;

  /// 目录规则是否按最新章节在前返回。
  final bool reverse;

  /// 本次实际访问的目录页数。
  final int pageCount;
}

/// 编排搜索结果到详情、目录的普通书源业务链路。
final class BookDetailService {
  /// 创建详情业务服务。
  const BookDetailService({
    required BookSourceGateway sourceGateway,
    required StandardBookSourceService standardService,
    required AppLogger logger,
  }) : _sourceGateway = sourceGateway,
       _standardService = standardService,
       _logger = logger;

  /// 书源查询边界。
  final BookSourceGateway _sourceGateway;

  /// 普通规则详情和目录服务。
  final StandardBookSourceService _standardService;

  /// 【搜书诊断日志】项目统一日志接口，用于记录详情和目录业务编排。
  final AppLogger _logger;

  /// 从搜索结果加载并合并详情字段。
  Future<BookDetailSnapshot> loadDetails({
    required SearchBook searchBook,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 【搜书诊断日志】搜索候选书籍不可逆标识。
    final String bookId = appLogDiagnosticId(searchBook.bookUrl);
    _logger.info(
      tag: bookDetailLogTag,
      message: '详情业务加载开始 bookId=$bookId sourceId=${appLogDiagnosticId(searchBook.origin)}',
    );
    /// 搜索结果声明的来源书源。
    final BookSource? source = await _sourceGateway.getByUrl(searchBook.origin);
    if (source == null) {
      _logger.warning(tag: bookDetailLogTag, message: '详情业务终止 bookId=$bookId reason=sourceMissing');
      throw const BookDetailException('原书源已不存在');
    }
    /// 搜索结果转换的基础书籍。
    final Book baseBook = searchBook.toBook(
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    /// 规则解析出的详情字段。
    final ParsedBookInfo parsed = await _standardService.loadBookInfo(
      source: source,
      book: baseBook,
      cancellationToken: cancellationToken,
    );
    /// 合并搜索事实与详情规则字段后的快照。
    final BookDetailSnapshot snapshot = BookDetailSnapshot(
      source: source,
      book: _merge(baseBook, parsed),
    );
    _logger.info(
      tag: bookDetailLogTag,
      message: '详情业务加载完成 bookId=$bookId hasTocUrl=${snapshot.book.tocUrl.isNotEmpty}',
    );
    return snapshot;
  }

  /// 加载完整分页目录；显式刷新可开启 Android `runPerJs` 对应的请求前脚本。
  Future<List<BookChapter>> loadToc({
    required BookDetailSnapshot snapshot,
    bool runPreUpdateJavaScript = false,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 【搜书诊断日志】详情页目录业务阶段对应的书籍不可逆标识。
    final String bookId = appLogDiagnosticId(snapshot.book.bookUrl);
    _logger.info(tag: bookTocLogTag, message: '详情页请求完整目录 bookId=$bookId');
    /// 完整目录结果。
    final List<BookChapter> chapters = await _standardService.loadToc(
      source: snapshot.source,
      book: snapshot.book,
      runPreUpdateJavaScript: runPreUpdateJavaScript,
      cancellationToken: cancellationToken,
    );
    _logger.info(
      tag: bookTocLogTag,
      message: '详情页取得完整目录 bookId=$bookId chapterCount=${chapters.length}',
    );
    return chapters;
  }

  /// 刷新书架中已有书籍；已有目录 URL 时避免重复请求详情。
  Future<RefreshedBookResult> refreshBook({
    required Book book,
    HttpCancellationToken? cancellationToken,
    String? initialPageUrl,
    int maximumPages = 100,
    Set<String> previouslyVisitedPageUrls = const <String>{},
  }) async {
    /// 当前书籍的来源书源。
    final BookSource? source = await _sourceGateway.getByUrl(book.origin);
    if (source == null) {
      throw const BookDetailException('原书源已不存在');
    }
    /// 目录 URL 缺失时先刷新详情，否则直接沿用书架事实。
    final Book detailBook;
    if (book.tocUrl.isEmpty) {
      /// 解析出的详情字段。
      final ParsedBookInfo parsed = await _standardService.loadBookInfo(
        source: source,
        book: book,
        cancellationToken: cancellationToken,
      );
      detailBook = _merge(book, parsed);
    } else {
      detailBook = book;
    }
    /// 完整刷新目录。
    final LoadedTocResult loadedToc =
        await _standardService.loadTocWithMetadata(
      source: source,
      book: detailBook,
      cancellationToken: cancellationToken,
      initialPageUrl: initialPageUrl,
      maxPages: maximumPages,
      previouslyVisitedPageUrls: previouslyVisitedPageUrls,
    );
    return RefreshedBookResult(
      book: withChapterSummary(detailBook, loadedToc.chapters),
      chapters: loadedToc.chapters,
      anchorPageUrl: loadedToc.anchorPageUrl,
      visitedPageUrls: loadedToc.visitedPageUrls,
      reverse: loadedToc.reverse,
      pageCount: loadedToc.pageCount,
    );
  }

  /// 用完整目录更新书籍章节统计，保持加入书架后的页面和数据库状态一致。
  Book withChapterSummary(Book book, List<BookChapter> chapters) {
    /// 最后一章标题；空目录保持详情已有标题。
    final String? latestTitle = chapters.isEmpty ? book.latestChapterTitle : chapters.last.title;
    /// 相比旧目录新增的章节数。
    final int newChapterCount = chapters.length > book.totalChapterNum
        ? chapters.length - book.totalChapterNum
        : 0;
    /// 只有发现新章节时才更新最新章节时间。
    final int latestTime = newChapterCount > 0
        ? DateTime.now().millisecondsSinceEpoch
        : book.latestChapterTime;
    return Book(
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      kind: book.kind,
      customTag: book.customTag,
      coverUrl: book.coverUrl,
      customCoverUrl: book.customCoverUrl,
      intro: book.intro,
      customIntro: book.customIntro,
      remark: book.remark,
      charset: book.charset,
      type: book.type,
      group: book.group,
      latestChapterTitle: latestTitle,
      latestChapterTime: latestTime,
      lastCheckTime: DateTime.now().millisecondsSinceEpoch,
      lastCheckCount: newChapterCount,
      totalChapterNum: chapters.length,
      durChapterTitle: book.durChapterTitle,
      durChapterIndex: book.durChapterIndex,
      durChapterPos: book.durChapterPos,
      durChapterTime: book.durChapterTime,
      wordCount: book.wordCount,
      canUpdate: book.canUpdate,
      order: book.order,
      originOrder: book.originOrder,
      variable: book.variable,
      readConfig: book.readConfig,
      syncTime: book.syncTime,
    );
  }

  /// 合并详情事实并保留书架相关默认字段。
  Book _merge(Book book, ParsedBookInfo parsed) {
    /// 当前详情完成时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    return Book(
      bookUrl: book.bookUrl,
      tocUrl: parsed.tocUrl ?? book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      name: parsed.name,
      author: parsed.author,
      kind: parsed.kind ?? book.kind,
      coverUrl: parsed.coverUrl ?? book.coverUrl,
      intro: parsed.intro ?? book.intro,
      type: book.type,
      latestChapterTitle: parsed.latestChapterTitle ?? book.latestChapterTitle,
      latestChapterTime: now,
      lastCheckTime: now,
      durChapterTime: book.durChapterTime,
      wordCount: parsed.wordCount ?? book.wordCount,
      originOrder: book.originOrder,
      variable: book.variable,
    );
  }

}

/// 表示详情业务可安全展示的受控异常。
final class BookDetailException implements Exception {
  /// 创建详情异常。
  const BookDetailException(this.message);

  /// 面向用户的错误摘要。
  final String message;
}
