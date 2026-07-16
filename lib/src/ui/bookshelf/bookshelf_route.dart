import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../help/logging/app_logger.dart';
import '../book_info/book_info_contract.dart';
import 'bookshelf_contract.dart';
import 'bookshelf_screen.dart';
import 'bookshelf_view_model.dart';

/// 连接书架 ViewModel、对话框、导航 Effect 和纯 UI 的路由层。
final class BookshelfRoute extends StatefulWidget {
  /// 创建书架路由。
  const BookshelfRoute({required this.dependencies, super.key});

  /// 应用组合根依赖。
  final AppDependencies dependencies;

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
  /// 当前已展示的业务对话框。
  BookshelfDialog? _shownDialog;

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
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 执行导航和 Snackbar 副作用。
  void _handleEffect(BookshelfEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case OpenBookshelfReaderEffect(book: final Book book):
        /// 【搜书诊断日志】现有产品路径从书架点击书籍后进入阅读路由。
        widget.dependencies.logger.info(
          tag: bookReaderEntryLogTag,
          message: '书架点击书籍，准备进入阅读器 bookId=${appLogDiagnosticId(book.bookUrl)} '
              'originId=${appLogDiagnosticId(book.origin)} chapterCount=${book.totalChapterNum}',
        );
        Navigator.of(context).pushNamed(AppRoute.reader, arguments: book.bookUrl);
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
        return BookshelfScreen(state: state, onIntent: _viewModel.onIntent);
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
