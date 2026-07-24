import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../components/app_state_views.dart';
import 'pdf_reader_route.dart';
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

  /// 详情页直接阅读时传入的未入架书籍快照。
  final Book? initialBook;

  /// 详情页直接阅读时传入的未入架目录快照。
  final List<BookChapter> initialChapters;

  /// 阅读入口，用于匿名埋点的受控枚举值。
  final String entry;

  /// 异步读取书籍并选择正确阅读内容模型。
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Book?>(
      future: _loadBook(),
      builder: (BuildContext context, AsyncSnapshot<Book?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        /// 数据库读取到的目标书籍。
        final Book? book = snapshot.data;
        if (book == null) {
          return const AppFatalErrorView(message: '目标书籍不存在或阅读历史已失效');
        }
        if (book.origin == 'loc_book' && book.originName.toLowerCase().endsWith('.pdf')) {
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
          initialBook: initialBook,
          initialChapters: initialChapters,
          entry: entry,
        );
      },
    );
  }

  /// 依次从书架、详情路由快照和阅读历史读取书籍事实。
  Future<Book?> _loadBook() async {
    final Book? shelfBook = await dependencies.bookshelfGateway.getBook(bookUrl);
    if (shelfBook != null) {
      return shelfBook;
    }
    final Book? routeBook = initialBook;
    if (routeBook != null && routeBook.bookUrl == bookUrl) {
      return routeBook;
    }
    return dependencies.readingHistoryGateway.getHistoryBook(bookUrl);
  }
}
