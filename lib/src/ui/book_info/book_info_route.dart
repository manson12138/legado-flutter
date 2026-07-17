import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

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

  /// 当前已经交给 Navigator 展示的书架冲突状态。
  BookInfoShelfConflictDialog? _shownShelfConflict;

  /// 创建 ViewModel 并开始监听 Effect。
  @override
  void initState() {
    super.initState();
    _viewModel = BookInfoViewModel(
      arguments: widget.arguments,
      detailService: widget.dependencies.bookDetailService,
      bookGroupGateway: widget.dependencies.bookGroupGateway,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      addBookToBookshelf: widget.dependencies.addBookToBookshelf,
      changeBookSource: widget.dependencies.changeBookSource,
      createBookshelfGroup: widget.dependencies.createBookshelfGroup,
      replaceBooksGroup: widget.dependencies.replaceBooksGroup,
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

  /// 根据 UiState 同步展示一次同名同作者书架冲突对话框。
  void _syncShelfConflict(BookInfoShelfConflictDialog? conflict) {
    if (conflict == null || identical(conflict, _shownShelfConflict)) {
      return;
    }
    _shownShelfConflict = conflict;
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) async {
      if (!mounted || !identical(conflict, _shownShelfConflict)) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return _BookInfoShelfConflictDialog(
            conflict: conflict,
            onReplace: () {
              Navigator.of(context).pop();
              _viewModel.onIntent(const ReplaceBookInfoShelfConflictIntent());
            },
            onAddAsNew: () {
              Navigator.of(context).pop();
              _viewModel.onIntent(const AddBookInfoShelfConflictAsNewIntent());
            },
          );
        },
      );
      if (identical(conflict, _shownShelfConflict)) {
        _shownShelfConflict = null;
        if (_viewModel.state.shelfConflict != null) {
          _viewModel.onIntent(const DismissBookInfoShelfConflictIntent());
        }
      }
    });
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
      case CopyBookInfoTextEffect(
        text: final String text,
        message: final String message,
      ):
        unawaited(_copyText(text, message));
      case ShareBookInfoEffect(title: final String title, text: final String text):
        unawaited(_shareBookInfo(title: title, text: text));
    }
  }

  /// 把详情页请求的文本写入系统剪贴板并反馈结果。
  Future<void> _copyText(String text, String successMessage) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(successMessage)));
    } on Object {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('复制失败')));
    }
  }

  /// 调用 Android/iOS 系统分享面板分享书籍基础信息。
  Future<void> _shareBookInfo({required String title, required String text}) async {
    try {
      /// iPad 分享面板需要锚点；使用当前路由根节点的全局区域。
      final RenderObject? renderObject = context.findRenderObject();
      /// 系统分享面板在大屏设备上的弹出锚点。
      final Rect? shareOrigin = renderObject is RenderBox
          ? renderObject.localToGlobal(Offset.zero) & renderObject.size
          : null;
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          title: title,
          subject: title,
          sharePositionOrigin: shareOrigin,
        ),
      );
    } on Object {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('分享失败')));
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
        _syncShelfConflict(state.shelfConflict);
        return BookInfoScreen(state: state, onIntent: _viewModel.onIntent);
      },
    );
  }
}

/// 展示现有来源与候选来源，并要求用户明确选择冲突处理方式。
final class _BookInfoShelfConflictDialog extends StatelessWidget {
  /// 创建同名同作者冲突对话框。
  const _BookInfoShelfConflictDialog({
    required this.conflict,
    required this.onReplace,
    required this.onAddAsNew,
  });

  /// 当前待确认的冲突事实。
  final BookInfoShelfConflictDialog conflict;

  /// 用候选来源替换现有书籍的回调。
  final VoidCallback onReplace;

  /// 明确保留两本书的回调。
  final VoidCallback onAddAsNew;

  /// 构建来源、目录和默认迁移含义说明。
  @override
  Widget build(BuildContext context) {
    /// 现有书源的安全显示名称。
    final String existingSource = conflict.existingBook.originName.isEmpty
        ? '未知来源'
        : conflict.existingBook.originName;
    /// 候选书源的安全显示名称。
    final String incomingSource = conflict.incomingBook.originName.isEmpty
        ? '未知来源'
        : conflict.incomingBook.originName;
    return AlertDialog(
      icon: const Icon(Icons.library_add_check_outlined),
      title: const Text('书架中已有同名书籍'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '《${conflict.incomingBook.name}》 · '
              '${conflict.incomingBook.author.isEmpty ? '未知作者' : conflict.incomingBook.author}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Text('现有来源：$existingSource（${conflict.existingBook.totalChapterNum} 章）'),
            const SizedBox(height: 8),
            Text('新来源：$incomingSource（${conflict.incomingChapters.length} 章）'),
            const SizedBox(height: 16),
            const Text('推荐替换现有书源；阅读进度、分组、排序、备注、封面和单书阅读设置会尽量保留。'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: onAddAsNew, child: const Text('仍然新增一本')),
        FilledButton(onPressed: onReplace, child: const Text('替换并保留数据')),
      ],
    );
  }
}
