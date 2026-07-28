import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../components/app_state_views.dart';
import 'pdf_reader_route.dart';
import 'reader_entry_shell.dart';
import 'reader_route.dart';

/// 在读取书籍事实后把 PDF 分流到页面阅读器，其余书籍进入 M8 文本阅读器。
final class BookReaderRoute extends StatelessWidget {
  /// 创建统一阅读入口。
  const BookReaderRoute({
    required this.dependencies,
    required this.bookUrl,
    this.initialChapterIndex,
    this.initialMessage,
    this.initialBook,
    this.initialIsInBookshelf,
    this.initialChapters = const <BookChapter>[],
    this.entry = 'bookshelf',
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 书架传入的稳定书籍 URL。
  final String bookUrl;

  /// 详情目录入口传入的初始章节索引；为空时沿用阅读进度。
  final int? initialChapterIndex;

  /// 路由替换后需要展示的一次性提示。
  final String? initialMessage;

  /// 书架、历史或详情入口直接传入的书籍快照。
  final Book? initialBook;

  /// 入口已经确认的书架成员事实；历史或详情入口未知时为空。
  final bool? initialIsInBookshelf;

  /// 详情页直接阅读时传入的未入架目录快照。
  final List<BookChapter> initialChapters;

  /// 阅读入口，用于匿名埋点的受控枚举值。
  final String entry;

  /// 优先使用路由书籍快照同步分流；旧路由缺少快照时才异步补查。
  @override
  Widget build(BuildContext context) {
    /// 主键匹配的路由书籍快照。
    final Book? routeBook =
        initialBook?.bookUrl == bookUrl ? initialBook : null;
    if (routeBook != null) {
      return _buildResolvedReader(
        routeBook,
        isInBookshelf: initialIsInBookshelf,
      );
    }
    return FutureBuilder<({Book book, bool isInBookshelf})?>(
      future: _loadBook(),
      builder: (
        BuildContext context,
        AsyncSnapshot<({Book book, bool isInBookshelf})?> snapshot,
      ) {
        if (snapshot.connectionState != ConnectionState.done) {
          /// 缺少新路由快照时保留兼容加载，但使用有业务含义的恢复壳替代转圈。
          /// 当前进程已经预加载完成或使用默认值的阅读显示配置。
          final config = dependencies.readerCacheGateway.currentDisplayConfig;
          return Scaffold(
            backgroundColor: Color(config.backgroundColorValue),
            body: SafeArea(
              child: ReaderEntryShell(
                book: null,
                chapterTitle: '',
                statusMessage: '正在恢复书籍信息',
                textColor: Color(config.textColorValue),
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ),
          );
        }
        /// 兼容查询得到的书籍与成员事实。
        final ({Book book, bool isInBookshelf})? resolved = snapshot.data;
        if (resolved == null) {
          return const AppFatalErrorView(message: '目标书籍不存在或阅读历史已失效');
        }
        return _buildResolvedReader(
          resolved.book,
          isInBookshelf: resolved.isInBookshelf,
        );
      },
    );
  }

  /// 根据已知书籍事实同步选择 PDF 或文本阅读器。
  Widget _buildResolvedReader(
    Book book, {
    required bool? isInBookshelf,
  }) {
    if (book.origin == 'loc_book' &&
        book.originName.toLowerCase().endsWith('.pdf')) {
      return PdfReaderRoute(
        dependencies: dependencies,
        book: book,
        entry: entry,
      );
    }
    return ReaderRoute(
      dependencies: dependencies,
      bookUrl: bookUrl,
      initialChapterIndex: initialChapterIndex,
      initialMessage: initialMessage,
      initialBook: book,
      initialIsInBookshelf: isInBookshelf,
      initialChapters: initialChapters,
      entry: entry,
    );
  }

  /// 旧字符串路由并行读取书架和历史，避免先查空书架后再串行等待历史。
  Future<({Book book, bool isInBookshelf})?> _loadBook() async {
    /// 书架与历史互相独立，可以同时发起本地查询。
    final Future<Book?> shelfFuture =
        dependencies.bookshelfGateway.getBook(bookUrl);
    final Future<Book?> historyFuture =
        dependencies.readingHistoryGateway.getHistoryBook(bookUrl);
    final Book? shelfBook = await shelfFuture;
    if (shelfBook != null) {
      return (book: shelfBook, isInBookshelf: true);
    }
    final Book? historyBook = await historyFuture;
    return historyBook == null
        ? null
        : (book: historyBook, isInBookshelf: false);
  }
}
