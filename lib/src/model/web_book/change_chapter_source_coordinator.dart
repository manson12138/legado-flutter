import '../../api/http/http_contract.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import '../reader/chapter_title_matcher.dart';
import 'book_detail_service.dart';
import 'book_search_coordinator.dart';
import 'standard_source_parser.dart';
import 'standard_source_service.dart';

/// 候选来源完成目录加载后的预览：目录、来源上下文和预选章节位置。
final class ChangeChapterSourceCandidateToc {
  /// 创建候选目录预览。
  ChangeChapterSourceCandidateToc({
    required this.source,
    required this.book,
    required List<BookChapter> chapters,
    required this.preselectedIndex,
  }) : chapters = List<BookChapter>.unmodifiable(chapters);

  /// 候选目录对应书源，供后续拉取章节正文使用。
  final BookSource source;

  /// 候选来源合并详情字段后的书籍事实。
  final Book book;

  /// 候选来源完整目录。
  final List<BookChapter> chapters;

  /// 按旧章节标题模糊匹配预选的目录索引；未找到合适位置时为 -1。
  final int preselectedIndex;
}

/// 复用整书换源的多源搜索与详情服务，在候选目录中定位单章内容来源。
///
/// 书籍级候选发现与 [ChangeSourceCoordinator] 完全一致（同名同作者过滤、排除自身）；
/// 章节级定位是本协调器独有的新增逻辑：加载候选完整目录后用 [resolveMatchingChapterIndex]
/// 模糊匹配预选章节，最终仍由用户手动确认要替换的目标章节。
final class ChangeChapterSourceCoordinator {
  /// 创建页面生命周期内使用的单章换源协调器。
  const ChangeChapterSourceCoordinator({
    required BookSearchCoordinator searchCoordinator,
    required BookDetailService detailService,
    required StandardBookSourceService standardService,
    required AppLogger logger,
  }) : _searchCoordinator = searchCoordinator,
       _detailService = detailService,
       _standardService = standardService,
       _logger = logger;

  /// 负责有界并发、取消、超时和失败分类的共享搜索协调器。
  final BookSearchCoordinator _searchCoordinator;

  /// 负责候选详情和完整目录解析的共享业务服务。
  final BookDetailService _detailService;

  /// 普通书源正文网络与规则服务，用于拉取候选目标章节正文。
  final StandardBookSourceService _standardService;

  /// 只记录不可逆书籍/书源标识和数量的统一日志器。
  final AppLogger _logger;

  /// 读取当前启用书源快照，页面只展示可参与搜索的来源。
  Future<List<BookSource>> loadEnabledSources() {
    return _searchCoordinator.loadEnabledSources();
  }

  /// 搜索全部或指定启用书源，过滤规则与整书换源一致。
  Future<BookSearchRun> startSearch({
    required Book book,
    required bool checkAuthor,
    required Set<String> selectedSourceUrls,
    required void Function(BookSearchEvent event) onEvent,
  }) {
    /// 去除首尾空白后的目标书名，保持大小写敏感的精确匹配语义。
    final String expectedName = book.name.trim();
    /// 去除首尾空白后的目标作者；关闭作者校验时不参与过滤。
    final String expectedAuthor = _normalizeAuthor(book.author);
    _logger.info(
      tag: bookSourceChangeLogTag,
      message: '单章换源候选搜索开始 bookId=${appLogDiagnosticId(book.bookUrl)} '
          'checkAuthor=$checkAuthor selectedSourceCount=${selectedSourceUrls.length}',
    );
    return _searchCoordinator.start(
      keyword: book.name,
      selectedSourceUrls: selectedSourceUrls,
      onEvent: (BookSearchEvent event) {
        switch (event) {
          case BookSearchResultsEvent(source: final source, books: final List<SearchBook> books):
            /// 当前书源中符合单章换源条件且不是当前记录自身的候选。
            final List<SearchBook> candidates = books.where((SearchBook candidate) {
              /// 书名精确匹配结果。
              final bool nameMatches = candidate.name.trim() == expectedName;
              /// 作者关闭校验时直接通过，开启时沿用包含判断。
              final bool authorMatches = !checkAuthor ||
                  expectedAuthor.isEmpty ||
                  candidate.author.trim().contains(expectedAuthor);
              /// 当前书源与当前书完全相同的结果不能作为单章换源目标。
              final bool isCurrentBook =
                  candidate.origin == book.origin && candidate.bookUrl == book.bookUrl;
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

  /// 加载候选完整目录并模糊预选与旧章节最接近的位置。
  Future<ChangeChapterSourceCandidateToc> loadCandidateToc({
    required SearchBook candidate,
    required int oldChapterIndex,
    required String oldChapterTitle,
    required int oldChapterListSize,
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
    /// 模糊匹配得到的预选目录索引。
    final int preselectedIndex = resolveMatchingChapterIndex(
      oldChapterIndex: oldChapterIndex,
      oldChapterTitle: oldChapterTitle,
      newChapters: chapters,
      oldChapterListSize: oldChapterListSize,
    );
    _logger.info(
      tag: bookSourceChangeLogTag,
      message: '单章换源候选目录加载完成 bookId=${appLogDiagnosticId(snapshot.book.bookUrl)} '
          'chapterCount=${chapters.length} preselectedIndex=$preselectedIndex',
    );
    return ChangeChapterSourceCandidateToc(
      source: snapshot.source,
      book: snapshot.book,
      chapters: chapters,
      preselectedIndex: preselectedIndex,
    );
  }

  /// 拉取候选目录中用户手动选定章节的正文。
  Future<String> fetchChapterContent({
    required BookSource source,
    required BookChapter chapter,
    required HttpCancellationToken cancellationToken,
  }) async {
    /// 候选章节解析后的正文页。
    final ParsedContentPage parsed = await _standardService.loadContent(
      source: source,
      chapter: chapter,
      cancellationToken: cancellationToken,
    );
    if (parsed.content.trim().isEmpty) {
      throw const BookDetailException('候选章节正文为空');
    }
    _logger.info(
      tag: bookSourceChangeLogTag,
      message: '单章换源候选正文取得 sourceId=${appLogDiagnosticId(source.bookSourceUrl)} '
          'chapterId=${appLogDiagnosticId(chapter.url)} contentLength=${parsed.content.length}',
    );
    return parsed.content;
  }

  /// 去除“作者:”前缀和“著”后缀，与整书换源保持一致的作者规范化规则。
  String _normalizeAuthor(String value) {
    return value
        .replaceFirst(RegExp(r'^\s*作\s*者[:：\s]+'), '')
        .replaceFirst(RegExp(r'\s+著'), '')
        .trim();
  }
}
