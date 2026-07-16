import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import 'book_info_contract.dart';
import 'book_info_screen.dart';
import 'book_info_view_model.dart';

/// 连接详情 ViewModel 生命周期、Effect 和纯 UI 的路由层。
final class BookInfoRoute extends StatefulWidget {
  /// 创建详情路由。
  const BookInfoRoute({required this.dependencies, required this.arguments, super.key});
  /// 应用组合根依赖。
  final AppDependencies dependencies;
  /// 搜索页传入的详情参数。
  final BookInfoRouteArguments arguments;

  /// 创建路由状态。
  @override
  State<BookInfoRoute> createState() => _BookInfoRouteState();
}

/// 持有详情 ViewModel 和 Effect 订阅。
final class _BookInfoRouteState extends State<BookInfoRoute> {
  /// 页面生命周期内唯一 ViewModel。
  late final BookInfoViewModel _viewModel;
  /// Effect 订阅。
  late final StreamSubscription<BookInfoEffect> _effectSubscription;

  /// 创建 ViewModel 并开始监听 Effect。
  @override
  void initState() {
    super.initState();
    _viewModel = BookInfoViewModel(
      arguments: widget.arguments,
      detailService: widget.dependencies.bookDetailService,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      addBookToBookshelf: widget.dependencies.addBookToBookshelf,
      saveBookChapters: widget.dependencies.saveBookChapters,
      cancellationTokenFactory: widget.dependencies.createHttpCancellationToken,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
    /// 路由替换后的提示等待详情 Scaffold 首帧完成再展示。
    final String? initialMessage = widget.arguments.initialMessage;
    if (initialMessage != null && initialMessage.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(initialMessage)),
          );
        }
      });
    }
  }

  /// 执行导航和 Snackbar 副作用。
  void _handleEffect(BookInfoEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case ShowBookInfoMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case CloseBookInfoEffect():
        Navigator.of(context).maybePop();
      case OpenBookInfoReaderEffect(
        bookUrl: final String bookUrl,
        chapterIndex: final int chapterIndex,
      ):
        Navigator.of(context).pushNamed(
          AppRoute.reader,
          arguments: ReaderRouteArguments(
            bookUrl: bookUrl,
            initialChapterIndex: chapterIndex,
          ),
        );
      case OpenBookInfoFullSourceChangeEffect(bookUrl: final String bookUrl):
        unawaited(_openFullSourceChange(bookUrl));
    }
  }

  /// 打开独立换源页面，成功后以新主键和新来源替换当前详情路由。
  Future<void> _openFullSourceChange(String oldBookUrl) async {
    /// 整书换源页面返回的事务结果。
    final ChangeBookSourceResult? result =
        await Navigator.of(context).pushNamed<ChangeBookSourceResult>(
      AppRoute.changeBookSource,
      arguments: ChangeBookSourceRouteArguments(bookUrl: oldBookUrl),
    );
    if (!mounted || result == null) {
      return;
    }
    /// 换源后持久化的新书籍事实。
    final Book book = result.book;
    /// 新详情路由所需的搜索候选模型。
    final SearchBook searchBook = SearchBook(
      bookUrl: book.bookUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      type: book.type,
      kind: book.kind,
      coverUrl: book.coverUrl,
      intro: book.intro,
      wordCount: book.wordCount,
      latestChapterTitle: book.latestChapterTitle,
      tocUrl: book.tocUrl,
      time: book.lastCheckTime,
      variable: book.variable,
      originOrder: book.originOrder,
    );
    /// 新详情页首帧展示的成功或非阻断警告。
    final String resultMessage = result.warnings.isEmpty
        ? '已切换到“${book.originName}”'
        : '换源已完成；${result.warnings.join('；')}';
    unawaited(
      Navigator.of(context).pushReplacementNamed<void, void>(
        AppRoute.bookInfo,
        arguments: BookInfoRouteArguments(
          group: BookSearchResultGroup(
            key: '${book.name.length}:${book.name}${book.author}',
            books: <SearchBook>[searchBook],
          ),
          selectedBook: searchBook,
          initialMessage: resultMessage,
        ),
      ),
    );
  }

  /// 释放订阅和 ViewModel。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅状态并连接纯 UI。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BookInfoUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<BookInfoUiState> snapshot) {
        /// 当前可渲染状态。
        final BookInfoUiState state = snapshot.data ?? _viewModel.state;
        return BookInfoScreen(state: state, onIntent: _viewModel.onIntent);
      },
    );
  }
}
