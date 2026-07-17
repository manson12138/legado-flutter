import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../help/logging/app_logger.dart';
import '../book_info/book_info_contract.dart';
import 'search_contract.dart';
import 'search_screen.dart';
import 'search_view_model.dart';

/// 连接搜索 ViewModel 生命周期、Effect 和纯 UI 的路由层。
final class SearchRoute extends StatefulWidget {
  /// 创建搜索路由。
  const SearchRoute({
    required this.dependencies,
    this.embedded = false,
    super.key,
  });
  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 是否嵌入应用一级导航；嵌入时不显示返回按钮。
  final bool embedded;

  /// 创建路由状态。
  @override
  State<SearchRoute> createState() => _SearchRouteState();
}

/// 持有搜索 ViewModel 与 Effect 订阅。
final class _SearchRouteState extends State<SearchRoute> {
  /// 页面生命周期内唯一 ViewModel。
  late final SearchViewModel _viewModel;
  /// Effect 订阅。
  late final StreamSubscription<SearchEffect> _effectSubscription;

  /// 创建 ViewModel 并开始监听 Effect。
  @override
  void initState() {
    super.initState();
    _viewModel = SearchViewModel(
      coordinator: widget.dependencies.createBookSearchCoordinator(),
      historyGateway: widget.dependencies.searchHistoryGateway,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 执行搜索页导航和提示副作用。
  void _handleEffect(SearchEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case OpenBookInfoEffect(group: final group, book: final book):
        /// 【搜书诊断日志】记录搜索结果点击后真正执行详情页导航的边界。
        widget.dependencies.logger.info(
          tag: bookDetailLogTag,
          message: '导航到书籍详情 candidateCount=${group.books.length} '
              'bookId=${appLogDiagnosticId(book.bookUrl)} '
              'sourceId=${appLogDiagnosticId(book.origin)}',
        );
        Navigator.of(context).pushNamed(
          AppRoute.bookInfo,
          arguments: BookInfoRouteArguments(group: group, selectedBook: book),
        );
      case ShowSearchMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case CloseSearchEffect():
        Navigator.of(context).maybePop();
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
    return StreamBuilder<SearchUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<SearchUiState> snapshot) {
        /// 当前可渲染状态。
        final SearchUiState state = snapshot.data ?? _viewModel.state;
        return SearchScreen(
          state: state,
          onIntent: _viewModel.onIntent,
          showBackButton: !widget.embedded,
        );
      },
    );
  }
}
