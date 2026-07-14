import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book.dart';
import '../components/app_state_views.dart';
import 'pdf_reader_route.dart';
import 'reader_route.dart';

/// 在读取书籍事实后把 PDF 分流到页面阅读器，其余书籍进入 M8 文本阅读器。
final class BookReaderRoute extends StatelessWidget {
  /// 创建统一阅读入口。
  const BookReaderRoute({required this.dependencies, required this.bookUrl, super.key});

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 书架传入的稳定书籍 URL。
  final String bookUrl;

  /// 异步读取书籍并选择正确阅读内容模型。
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Book?>(
      future: dependencies.bookshelfGateway.getBook(bookUrl),
      builder: (BuildContext context, AsyncSnapshot<Book?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        /// 数据库读取到的目标书籍。
        final Book? book = snapshot.data;
        if (book == null) {
          return const AppFatalErrorView(message: '目标书籍已不在书架中');
        }
        if (book.origin == 'loc_book' && book.originName.toLowerCase().endsWith('.pdf')) {
          return PdfReaderRoute(dependencies: dependencies, book: book);
        }
        return ReaderRoute(dependencies: dependencies, bookUrl: bookUrl);
      },
    );
  }
}
