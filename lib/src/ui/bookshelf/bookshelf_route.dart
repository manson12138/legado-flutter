import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../app/reader_transition_spec.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../help/logging/app_logger.dart';
import '../book_info/book_info_contract.dart';
import '../components/app_scaffold.dart';
import 'bookshelf_contract.dart';
import 'bookshelf_page_switcher.dart';
import 'bookshelf_screen.dart';
import 'bookshelf_view_model.dart';
import 'reading_history_contract.dart';
import 'reading_history_screen.dart';
import 'reading_history_view_model.dart';

/// 连接书架 ViewModel、对话框、导航 Effect 和纯 UI 的路由层。
final class BookshelfRoute extends StatefulWidget {
  /// 创建书架路由。
  const BookshelfRoute({
    required this.dependencies,
    this.embedded = false,
    this.visibilityListenable,
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 是否嵌入应用一级导航；嵌入时普通顶部栏不显示返回按钮。
  final bool embedded;

  /// 一级主导航是否正在展示书架目的地；隐藏时自动退出选择模式。
  final ValueListenable<bool>? visibilityListenable;

  /// 创建路由状态。
  @override
  State<BookshelfRoute> createState() => _BookshelfRouteState();
}

/// 持有书架 ViewModel、Effect 订阅和对话框生命周期。
final class _BookshelfRouteState extends State<BookshelfRoute> {
  /// 页面生命周期内唯一 ViewModel。
  late final BookshelfViewModel _viewModel;
  /// Effect 订阅。
  late final StreamSubscription<BookshelfEffect> _effectSubscription;
  /// 页面生命周期内唯一阅读历史 ViewModel。
  late final ReadingHistoryViewModel _historyViewModel;
  /// 阅读历史 Effect 订阅。
  late final StreamSubscription<ReadingHistoryEffect>
      _historyEffectSubscription;
  /// 书架和历史双页控制器。
  late final PageController _pageController;
  /// 固定顶部页签使用的当前横滑进度，范围为书架 0 到历史 1。
  double _pageProgress = 0;
  /// 当前已展示的业务对话框。
  BookshelfDialog? _shownDialog;

  /// 是否已有书架或历史阅读导航在栈中，阻止快速双击创建重复阅读器。
  bool _openingReader = false;

  /// 创建 ViewModel 并监听 Effect。
  @override
  void initState() {
    super.initState();
    _viewModel = BookshelfViewModel(
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      bookGroupGateway: widget.dependencies.bookGroupGateway,
      deleteBooks: widget.dependencies.deleteBooksFromBookshelf,
      createGroup: widget.dependencies.createBookshelfGroup,
      replaceBooksGroup: widget.dependencies.replaceBooksGroup,
      refreshCoordinator: widget.dependencies.createBookshelfRefreshCoordinator(),
      layoutPreferences: widget.dependencies.bookshelfLayoutPreferences,
      startupPreloader: widget.dependencies.bookshelfHistoryStartupPreloader,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
    _historyViewModel = ReadingHistoryViewModel(
      widget.dependencies.readingHistoryGateway,
      widget.dependencies.bookshelfLayoutPreferences,
      widget.dependencies.bookshelfHistoryStartupPreloader,
    );
    _historyEffectSubscription =
        _historyViewModel.effects.listen(_handleHistoryEffect);
    _pageController = PageController();
    _pageController.addListener(_handlePageScroll);
    widget.visibilityListenable?.addListener(_handleVisibilityChanged);
  }

  /// 一级目的地隐藏时清空批量选择，避免回到书架继续误操作。
  void _handleVisibilityChanged() {
    if (widget.visibilityListenable?.value == false &&
        _viewModel.state.selectionMode) {
      _viewModel.onIntent(const ExitBookshelfSelectionIntent());
    }
  }

  /// 切换书架或历史页，并在书架不可见时退出选择模式。
  void _selectPage(int index) {
    final int targetIndex = index.clamp(0, 1).toInt();
    if (targetIndex != 0) {
      _viewModel.onIntent(const ExitBookshelfSelectionIntent());
    }
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 处理横向翻页完成，离开书架页时取消选择模式。
  void _handlePageChanged(int index) {
    if (index != 0) {
      _viewModel.onIntent(const ExitBookshelfSelectionIntent());
    }
  }

  /// 在内容页横滑期间仅更新固定顶部页签的轻量动画状态。
  void _handlePageScroll() {
    if (!_pageController.hasClients) {
      return;
    }
    final double? page = _pageController.page;
    if (page == null || (page - _pageProgress).abs() < 0.001 || !mounted) {
      return;
    }
    setState(() {
      _pageProgress = page.clamp(0.0, 1.0).toDouble();
    });
  }

  /// 处理固定顶部三项操作，并根据当前书架或历史页决定可执行行为。
  void _handleTopAction(int actionIndex) {
    final bool onBookshelf = _pageProgress < 0.5;
    if (actionIndex == 0) {
      _viewModel.onIntent(const OpenBookshelfLocalBookImportIntent());
      return;
    }
    switch (actionIndex) {
      case 1:
        if (onBookshelf) {
          _viewModel.onIntent(const ToggleBookshelfLayoutIntent());
        } else {
          _historyViewModel.onIntent(const ToggleReadingHistoryLayoutIntent());
        }
      case 2:
        if (onBookshelf) {
          _viewModel.onIntent(
            _viewModel.state.refreshing
                ? const CancelBookshelfRefreshIntent()
                : const RefreshBookshelfIntent(),
          );
        } else {
          _historyViewModel.onIntent(const RefreshReadingHistoryIntent());
        }
    }
  }

  /// 构建固定在页面上方的书架/历史公共操作栏。
  PreferredSizeWidget _buildTopAppBar(BookshelfUiState state) {
    if (state.selectionMode && _pageProgress < 0.5) {
      return AppBar(
        leading: IconButton(
          onPressed: () => _viewModel.onIntent(const ExitBookshelfSelectionIntent()),
          icon: const Icon(Icons.close),
          tooltip: '退出选择',
        ),
        title: Text('已选择 ${state.selectedBookUrls.length} 本'),
        actions: <Widget>[
          IconButton(onPressed: () => _viewModel.onIntent(const SelectAllBookshelfBooksIntent()), icon: const Icon(Icons.select_all), tooltip: '全选当前列表'),
          IconButton(onPressed: () => _viewModel.onIntent(const RefreshBookshelfIntent()), icon: const Icon(Icons.refresh), tooltip: '刷新选中书籍'),
          IconButton(onPressed: () => _viewModel.onIntent(const RequestMoveBookshelfBooksIntent()), icon: const Icon(Icons.drive_file_move_outline), tooltip: '移动分组'),
          IconButton(onPressed: state.selectedBookUrls.length == 1 ? () => _viewModel.onIntent(const OpenSelectedBookSourceChangeIntent()) : null, icon: const Icon(Icons.swap_horiz), tooltip: '整书换源'),
          IconButton(onPressed: () => _viewModel.onIntent(const RequestDeleteBookshelfBooksIntent()), icon: const Icon(Icons.delete_outline), tooltip: '删除'),
        ],
      );
    }
    return AppBar(
      automaticallyImplyLeading: false,
      centerTitle: false,
      leading: widget.embedded
          ? null
          : IconButton(
              onPressed: () => _viewModel.onIntent(const BackFromBookshelfIntent()),
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回',
            ),
      title: BookshelfPageSwitcher(
        pageProgress: _pageProgress,
        onSelected: _selectPage,
      ),
      actions: <Widget>[
        IconButton(onPressed: () => _handleTopAction(0), icon: const Icon(Icons.upload_file_outlined), tooltip: '导入本地书'),
        IconButton(onPressed: () => _handleTopAction(1), icon: Icon(_pageProgress < 0.5 && state.layoutMode == BookshelfLayoutMode.grid ? Icons.view_list : Icons.grid_view), tooltip: '切换列表或网格'),
        IconButton(onPressed: () => _handleTopAction(2), icon: Icon(_pageProgress < 0.5 && state.refreshing ? Icons.stop_circle_outlined : Icons.refresh), tooltip: _pageProgress < 0.5 && state.refreshing ? '停止刷新' : '刷新'),
      ],
    );
  }

  /// 从历史页按明确 history 入口打开阅读器。
  void _handleHistoryEffect(ReadingHistoryEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case OpenReadingHistoryReaderEffect(
        book: final Book book,
        transitionSpec: final ReaderTransitionSpec? transitionSpec,
      ):
        unawaited(
          _openReader(
            book: book,
            entry: 'history',
            isInBookshelf: null,
            transitionSpec: transitionSpec,
          ),
        );
    }
  }

  /// 执行导航和 Snackbar 副作用。
  void _handleEffect(BookshelfEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case OpenBookshelfReaderEffect(
        book: final Book book,
        transitionSpec: final ReaderTransitionSpec? transitionSpec,
      ):
        /// 【搜书诊断日志】现有产品路径从书架点击书籍后进入阅读路由。
        widget.dependencies.logger.info(
          tag: bookReaderEntryLogTag,
          message: '书架点击书籍，准备进入阅读器 bookId=${appLogDiagnosticId(book.bookUrl)} '
              'originId=${appLogDiagnosticId(book.origin)} chapterCount=${book.totalChapterNum}',
        );
        unawaited(
          _openReader(
            book: book,
            entry: 'bookshelf',
            isInBookshelf: true,
            transitionSpec: transitionSpec,
          ),
        );
      case OpenBookshelfBookInfoEffect(book: final Book book):
        /// 将书架书转换为详情路由所需候选来源。
        final SearchBook searchBook = _toSearchBook(book);
        Navigator.of(context).pushNamed(
          AppRoute.bookInfo,
          arguments: BookInfoRouteArguments(
            group: BookSearchResultGroup(
              key: '${book.name.length}:${book.name}${book.author}',
              books: <SearchBook>[searchBook],
            ),
            selectedBook: searchBook,
            analyticsEntry: 'bookshelf',
          ),
        );
      case ShowBookshelfMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case CloseBookshelfEffect():
        Navigator.of(context).maybePop();
      case OpenBookshelfLocalBookImportEffect():
        Navigator.of(context).pushNamed(AppRoute.localBookImport);
      case OpenBookshelfChangeSourceEffect(book: final Book book):
        unawaited(_openChangeSource(book));
    }
  }

  /// 单飞打开阅读器；点击几何只服务进入动画，返回统一使用短淡出。
  Future<void> _openReader({
    required Book book,
    required String entry,
    required bool? isInBookshelf,
    required ReaderTransitionSpec? transitionSpec,
  }) async {
    if (_openingReader || !mounted) {
      return;
    }
    _openingReader = true;
    try {
      /// FLUTTER_REWRITE_DEBUG_LOG：只记录导航开始和一次性转场 ID，不输出书籍或封面地址。
      final ReaderTransitionSpec? diagnosticTransitionSpec =
          transitionSpec;
      if (diagnosticTransitionSpec != null &&
          (diagnosticTransitionSpec.kind ==
                  ReaderTransitionKind.bookshelf ||
              diagnosticTransitionSpec.kind ==
                  ReaderTransitionKind.history)) {
        widget.dependencies.logger.info(
          tag: readerCoverTransitionLogTag,
          message: '$readerCoverTransitionDebugLogMarker '
              'event=navigation_push '
              'transitionId=${diagnosticTransitionSpec.id} '
              'entry=${diagnosticTransitionSpec.kind.name} '
              'sourceRectPresent='
              '${diagnosticTransitionSpec.sourceRect != null}',
        );
      }
      await Navigator.of(context).pushNamed<void>(
        AppRoute.reader,
        arguments: ReaderRouteArguments(
          bookUrl: book.bookUrl,
          initialBook: book,
          initialIsInBookshelf: isInBookshelf,
          transitionSpec: transitionSpec,
          entry: entry,
        ),
      );
    } finally {
      _openingReader = false;
    }
  }

  /// 打开整书换源页面，并在返回后展示新来源和非阻断迁移提示。
  Future<void> _openChangeSource(Book book) async {
    /// 整书换源页面返回的事务结果。
    final ChangeBookSourceResult? result =
        await Navigator.of(context).pushNamed<ChangeBookSourceResult>(
      AppRoute.changeBookSource,
      arguments: ChangeBookSourceRouteArguments(bookUrl: book.bookUrl),
    );
    if (!mounted || result == null) {
      return;
    }
    /// 换源成功后的提示，附带可能存在的配置复制警告。
    final String message = result.warnings.isEmpty
        ? '已切换到“${result.book.originName}”'
        : '换源已完成；${result.warnings.join('；')}';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 将持久化书籍转换为详情页搜索候选，不改变核心实体。
  SearchBook _toSearchBook(Book book) {
    return SearchBook(
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
  }

  /// 根据 UiState 同步一次业务对话框。
  void _syncDialog(BookshelfDialog? dialog) {
    if (dialog == null || identical(dialog, _shownDialog)) {
      return;
    }
    _shownDialog = dialog;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) async {
      if (!mounted || !identical(dialog, _shownDialog)) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => _buildDialog(dialog),
      );
      if (identical(dialog, _shownDialog)) {
        _shownDialog = null;
        _viewModel.onIntent(const DismissBookshelfDialogIntent());
      }
    });
  }

  /// 构建删除或移动分组对话框。
  Widget _buildDialog(BookshelfDialog dialog) {
    return switch (dialog) {
      DeleteBookshelfBooksDialog(bookUrls: final Set<String> bookUrls) => AlertDialog(
        title: const Text('确认删除书籍'),
        content: Text('将从书架删除 ${bookUrls.length} 本书，并由数据库级联删除其目录。不会删除本地原始文件。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _viewModel.onIntent(const ConfirmDeleteBookshelfBooksIntent());
            },
            child: const Text('删除'),
          ),
        ],
      ),
      MoveBookshelfBooksDialog() => _MoveBooksDialog(
        groups: _viewModel.state.groups,
        onMove: (int groupId) {
          Navigator.of(context).pop();
          _viewModel.onIntent(ConfirmMoveBookshelfBooksIntent(groupId));
        },
        onCreate: (String name) {
          Navigator.of(context).pop();
          _viewModel.onIntent(CreateAndMoveBookshelfGroupIntent(name));
        },
      ),
    };
  }

  /// 释放订阅和 ViewModel。
  @override
  void dispose() {
    widget.visibilityListenable?.removeListener(_handleVisibilityChanged);
    _pageController.removeListener(_handlePageScroll);
    _pageController.dispose();
    _historyEffectSubscription.cancel();
    _historyViewModel.dispose();
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅状态并连接纯 UI。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BookshelfUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<BookshelfUiState> snapshot) {
        /// 当前可渲染状态。
        final BookshelfUiState state = snapshot.data ?? _viewModel.state;
        _syncDialog(state.dialog);
        return PopScope<Object?>(
          canPop: !state.selectionMode,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop && state.selectionMode) {
              _viewModel.onIntent(
                const ExitBookshelfSelectionIntent(),
              );
            }
          },
          child: AppScaffold(
            appBar: _buildTopAppBar(state),
            body: PageView(
              controller: _pageController,
              onPageChanged: _handlePageChanged,
              children: <Widget>[
                BookshelfScreen(
                  state: state,
                  onIntent: _viewModel.onIntent,
                  onPageSelected: _selectPage,
                  showBackButton: !widget.embedded,
                ),
                StreamBuilder<ReadingHistoryUiState>(
                  stream: _historyViewModel.states,
                  initialData: _historyViewModel.state,
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<ReadingHistoryUiState> snapshot,
                  ) {
                    return ReadingHistoryScreen(
                      state: snapshot.data ?? _historyViewModel.state,
                      onIntent: _historyViewModel.onIntent,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 保存新分组名称输入并展示已有用户分组。
final class _MoveBooksDialog extends StatefulWidget {
  /// 创建移动分组对话框。
  const _MoveBooksDialog({
    required this.groups,
    required this.onMove,
    required this.onCreate,
  });

  /// 当前可选分组。
  final List<BookshelfGroupItem> groups;
  /// 选择已有分组回调。
  final ValueChanged<int> onMove;
  /// 创建新分组回调。
  final ValueChanged<String> onCreate;

  /// 创建对话框状态。
  @override
  State<_MoveBooksDialog> createState() => _MoveBooksDialogState();
}

/// 持有新分组名称控制器。
final class _MoveBooksDialogState extends State<_MoveBooksDialog> {
  /// 新分组名称控制器。
  final TextEditingController _controller = TextEditingController();

  /// 释放输入控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建已有分组列表和新建入口。
  @override
  Widget build(BuildContext context) {
    /// 可选择的正数用户分组。
    final List<BookshelfGroupItem> userGroups = widget.groups.where(
      (BookshelfGroupItem item) => item.group.groupId > 0,
    ).toList(growable: false);
    return AlertDialog(
      title: const Text('移动到分组'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: const Text('清除用户分组'),
                onTap: () => widget.onMove(0),
              ),
              ...userGroups.map((BookshelfGroupItem item) {
                return ListTile(
                  title: Text(item.group.groupName),
                  trailing: Text('${item.bookCount}'),
                  onTap: () => widget.onMove(item.group.groupId),
                );
              }),
              const Divider(),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: '新分组名称',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => widget.onCreate(_controller.text),
          child: const Text('新建并移动'),
        ),
      ],
    );
  }
}
