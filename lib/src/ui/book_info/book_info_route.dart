import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
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
    }
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
