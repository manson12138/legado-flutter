import '../../api/http/http_contract.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import 'book_detail_service.dart';
import 'book_search_coordinator.dart';

/// 保存换源候选完成详情和目录解析后的不可变预览。
final class ChangeSourceCandidatePreview {
  /// 创建包含新书籍事实和完整目录的候选预览。
  ChangeSourceCandidatePreview({
    required this.book,
    required List<BookChapter> chapters,
  }) : chapters = List<BookChapter>.unmodifiable(chapters);

  /// 合并搜索与详情字段并带目录统计的新书籍。
  final Book book;

  /// 候选来源的完整连续目录。
  final List<BookChapter> chapters;
}

/// 复用 M6 搜索与详情服务，编排 M11 整书换源候选发现和预览。
final class ChangeSourceCoordinator {
  /// 创建页面生命周期内使用的换源协调器。
  const ChangeSourceCoordinator({
    required BookSearchCoordinator searchCoordinator,
    required BookDetailService detailService,
    required AppLogger logger,
  }) : _searchCoordinator = searchCoordinator,
       _detailService = detailService,
       _logger = logger;

  /// 负责有界并发、取消、超时和失败分类的共享搜索协调器。
  final BookSearchCoordinator _searchCoordinator;

  /// 负责候选详情和完整目录解析的共享业务服务。
  final BookDetailService _detailService;

  /// 只记录不可逆书籍/书源标识和数量的统一日志器。
  final AppLogger _logger;

  /// 读取当前启用书源快照，页面只展示可参与搜索的来源。
  Future<List<BookSource>> loadEnabledSources() {
    return _searchCoordinator.loadEnabledSources();
  }

  /// 搜索全部或指定启用书源，并只向页面发布符合书名作者规则的候选。
  Future<BookSearchRun> startSearch({
    required Book oldBook,
    required bool checkAuthor,
    required Set<String> selectedSourceUrls,
    required void Function(BookSearchEvent event) onEvent,
  }) {
    /// 去除首尾空白后的目标书名，保持大小写敏感的 Android 精确匹配语义。
    final String expectedName = oldBook.name.trim();
    /// 去除首尾空白后的目标作者；关闭作者校验时不参与过滤。
    final String expectedAuthor = _normalizeAuthor(oldBook.author);
    _logger.info(
      tag: bookSourceChangeLogTag,
      message: '换源候选搜索开始 oldBookId=${appLogDiagnosticId(oldBook.bookUrl)} '
          'checkAuthor=$checkAuthor selectedSourceCount=${selectedSourceUrls.length}',
    );
    return _searchCoordinator.start(
      keyword: oldBook.name,
      selectedSourceUrls: selectedSourceUrls,
      onEvent: (BookSearchEvent event) {
        switch (event) {
          case BookSearchResultsEvent(source: final source, books: final List<SearchBook> books):
            /// 当前书源中符合整书换源条件且不是当前记录自身的候选。
            final List<SearchBook> candidates = books.where((SearchBook book) {
              /// 书名精确匹配结果。
              final bool nameMatches = book.name.trim() == expectedName;
              /// 作者关闭校验时直接通过，开启时沿用 Android 的包含判断。
              final bool authorMatches = !checkAuthor ||
                  expectedAuthor.isEmpty ||
                  book.author.trim().contains(expectedAuthor);
              /// 当前书源与当前详情 URL 完全相同的结果不能作为换源目标。
              final bool isCurrentBook = book.origin == oldBook.origin &&
                  book.bookUrl == oldBook.bookUrl;
              return nameMatches && authorMatches && !isCurrentBook;
            }).toList(growable: false);
            if (candidates.isNotEmpty) {
              onEvent(BookSearchResultsEvent(source: source, books: candidates));
            }
          case BookSearchFailureEvent():
            onEvent(event);
          case BookSearchProgressEvent():
            onEvent(event);
        }
      },
    );
  }

  /// 加载候选详情与完整目录，空目录保留为明确失败而不是可提交预览。
  Future<ChangeSourceCandidatePreview> loadCandidate({
    required SearchBook candidate,
    required HttpCancellationToken cancellationToken,
  }) async {
    /// 候选详情与来源上下文。
    final BookDetailSnapshot snapshot = await _detailService.loadDetails(
      searchBook: candidate,
      cancellationToken: cancellationToken,
    );
    /// 候选完整目录。
    final List<BookChapter> chapters = await _detailService.loadToc(
      snapshot: snapshot,
      cancellationToken: cancellationToken,
    );
    if (chapters.isEmpty) {
      throw const BookDetailException('目标来源目录为空');
    }
    /// 写入目录总数和最新章节标题后的候选书籍。
    final Book book = _detailService.withChapterSummary(snapshot.book, chapters);
    _logger.info(
      tag: bookSourceChangeLogTag,
      message: '换源候选预览完成 bookId=${appLogDiagnosticId(book.bookUrl)} '
          'sourceId=${appLogDiagnosticId(book.origin)} chapterCount=${chapters.length}',
    );
    return ChangeSourceCandidatePreview(book: book, chapters: chapters);
  }

  /// 去除 Android `AppPattern.authorRegex` 对应的“作者:”前缀和“著”后缀。
  String _normalizeAuthor(String value) {
    return value
        .replaceFirst(RegExp(r'^\s*作\s*者[:：\s]+'), '')
        .replaceFirst(RegExp(r'\s+著'), '')
        .trim();
  }
}
