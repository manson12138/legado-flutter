import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
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
  RefreshedBookResult({required this.book, required List<BookChapter> chapters})
    : chapters = List<BookChapter>.unmodifiable(chapters);

  /// 已更新目录统计的书籍。
  final Book book;

  /// 完整目录。
  final List<BookChapter> chapters;
}

/// 编排搜索结果到详情、目录的普通书源业务链路。
final class BookDetailService {
  /// 创建详情业务服务。
  const BookDetailService({
    required BookSourceGateway sourceGateway,
    required StandardBookSourceService standardService,
  }) : _sourceGateway = sourceGateway,
       _standardService = standardService;

  /// 书源查询边界。
  final BookSourceGateway _sourceGateway;

  /// 普通规则详情和目录服务。
  final StandardBookSourceService _standardService;

  /// 从搜索结果加载并合并详情字段。
  Future<BookDetailSnapshot> loadDetails({
    required SearchBook searchBook,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 搜索结果声明的来源书源。
    final BookSource? source = await _sourceGateway.getByUrl(searchBook.origin);
    if (source == null) {
      throw const BookDetailException('原书源已不存在');
    }
    if (_requiresJavaScript(source)) {
      throw const BookDetailException('该详情依赖 JavaScript，需等待 M04 真机兼容验收');
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
    return BookDetailSnapshot(source: source, book: _merge(baseBook, parsed));
  }

  /// 加载完整分页目录；服务层负责 URL 去重和连续索引。
  Future<List<BookChapter>> loadToc({
    required BookDetailSnapshot snapshot,
    HttpCancellationToken? cancellationToken,
  }) {
    return _standardService.loadToc(
      source: snapshot.source,
      book: snapshot.book,
      cancellationToken: cancellationToken,
    );
  }

  /// 刷新书架中已有书籍；已有目录 URL 时避免重复请求详情。
  Future<RefreshedBookResult> refreshBook({
    required Book book,
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 当前书籍的来源书源。
    final BookSource? source = await _sourceGateway.getByUrl(book.origin);
    if (source == null) {
      throw const BookDetailException('原书源已不存在');
    }
    if (_requiresJavaScript(source)) {
      throw const BookDetailException('该书源依赖 JavaScript，需等待 M04 真机兼容验收');
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
    final List<BookChapter> chapters = await _standardService.loadToc(
      source: source,
      book: detailBook,
      cancellationToken: cancellationToken,
    );
    return RefreshedBookResult(
      book: withChapterSummary(detailBook, chapters),
      chapters: chapters,
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

  /// 判断当前普通规则服务不能安全执行的脚本字段。
  bool _requiresJavaScript(BookSource source) {
    if (source.jsLib?.trim().isNotEmpty == true) {
      return true;
    }
    /// 详情和目录链路相关规则。
    final String rules = <String?>[
      source.ruleBookInfo,
      source.ruleToc,
    ].whereType<String>().join('\n');
    return RegExp(r'@js:|<js>|js@|Packages\.|JavaImporter|java\.', caseSensitive: false)
        .hasMatch(rules);
  }
}

/// 表示详情业务可安全展示的受控异常。
final class BookDetailException implements Exception {
  /// 创建详情异常。
  const BookDetailException(this.message);

  /// 面向用户的错误摘要。
  final String message;
}
