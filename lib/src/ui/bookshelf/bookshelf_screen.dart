import 'package:flutter/material.dart';

import '../../model/bookshelf/bookshelf_refresh_coordinator.dart';
import '../components/app_scaffold.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'bookshelf_contract.dart';

/// 只消费 BookshelfUiState 并发送 Intent 的无状态书架页面。
final class BookshelfScreen extends StatelessWidget {
  /// 创建书架纯 UI。
  const BookshelfScreen({
    required this.state,
    required this.onIntent,
    this.showBackButton = true,
    super.key,
  });

  /// ViewModel 提供的完整不可变状态。
  final BookshelfUiState state;
  /// 用户操作统一入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 普通模式顶部栏是否展示返回按钮。
  final bool showBackButton;

  /// 构建选择模式或普通模式顶部栏和共享页面状态。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: state.selectionMode ? _selectionAppBar() : _normalAppBar(),
      body: Column(
        children: <Widget>[
          if (!state.selectionMode) _BookshelfControls(state: state, onIntent: onIntent),
          if (state.refreshing || state.refreshProgress.total > 0)
            _BookshelfRefreshStatus(state: state, onIntent: onIntent),
          if (state.refreshFailures.isNotEmpty)
            _BookshelfRefreshFailures(failures: state.refreshFailures),
          Expanded(child: _BookshelfBody(state: state, onIntent: onIntent)),
        ],
      ),
    );
  }

  /// 构建普通顶部栏。
  PreferredSizeWidget _normalAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      leading: showBackButton
          ? IconButton(
              onPressed: () => onIntent(const BackFromBookshelfIntent()),
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回',
            )
          : null,
      title: const Text('书架'),
      actions: <Widget>[
        IconButton(
          onPressed: () => onIntent(const OpenBookshelfLocalBookImportIntent()),
          icon: const Icon(Icons.upload_file_outlined),
          tooltip: '导入本地书',
        ),
        IconButton(
          onPressed: () => onIntent(const ToggleBookshelfLayoutIntent()),
          icon: Icon(state.layoutMode == BookshelfLayoutMode.grid ? Icons.view_list : Icons.grid_view),
          tooltip: '切换列表或网格',
        ),
        IconButton(
          onPressed: state.refreshing
              ? () => onIntent(const CancelBookshelfRefreshIntent())
              : () => onIntent(const RefreshBookshelfIntent()),
          icon: Icon(state.refreshing ? Icons.stop_circle_outlined : Icons.refresh),
          tooltip: state.refreshing ? '停止刷新' : '刷新目录',
        ),
      ],
    );
  }

  /// 构建选择模式顶部栏。
  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        onPressed: () => onIntent(const ExitBookshelfSelectionIntent()),
        icon: const Icon(Icons.close),
        tooltip: '退出选择',
      ),
      title: Text('已选择 ${state.selectedBookUrls.length} 本'),
      actions: <Widget>[
        IconButton(
          onPressed: () => onIntent(const SelectAllBookshelfBooksIntent()),
          icon: const Icon(Icons.select_all),
          tooltip: '全选当前列表',
        ),
        IconButton(
          onPressed: () => onIntent(const RefreshBookshelfIntent()),
          icon: const Icon(Icons.refresh),
          tooltip: '刷新选中书籍',
        ),
        IconButton(
          onPressed: () => onIntent(const RequestMoveBookshelfBooksIntent()),
          icon: const Icon(Icons.drive_file_move_outline),
          tooltip: '移动分组',
        ),
        IconButton(
          onPressed: state.selectedBookUrls.length == 1
              ? () => onIntent(const OpenSelectedBookSourceChangeIntent())
              : null,
          icon: const Icon(Icons.swap_horiz),
          tooltip: '整书换源',
        ),
        IconButton(
          onPressed: () => onIntent(const RequestDeleteBookshelfBooksIntent()),
          icon: const Icon(Icons.delete_outline),
          tooltip: '删除',
        ),
      ],
    );
  }
}

/// 展示搜索、分组和排序控制。
final class _BookshelfControls extends StatelessWidget {
  /// 创建控制区。
  const _BookshelfControls({required this.state, required this.onIntent});
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 构建共享筛选控件。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.small,
        SpacingToken.medium,
        0,
      ),
      child: Column(
        children: <Widget>[
          TextFormField(
            key: ValueKey<String>('bookshelf-${state.query.isEmpty}'),
            initialValue: state.query,
            onChanged: (String value) => onIntent(ChangeBookshelfQueryIntent(value)),
            decoration: InputDecoration(
              hintText: '搜索书架',
              prefixIcon: const Icon(Icons.search, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: SpacingToken.mediumSmall,
                vertical: SpacingToken.small,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RadiusToken.pill),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RadiusToken.pill),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RadiusToken.pill),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 1,
                ),
              ),
              suffixIcon: PopupMenuButton<BookshelfSortMode>(
                tooltip: '选择排序',
                icon: const Icon(Icons.sort),
                onSelected: (BookshelfSortMode value) => onIntent(ChangeBookshelfSortIntent(value)),
                itemBuilder: (BuildContext context) => BookshelfSortMode.values.map((BookshelfSortMode value) {
                  return CheckedPopupMenuItem<BookshelfSortMode>(
                    value: value,
                    checked: value == state.sortMode,
                    child: Text(_sortName(value)),
                  );
                }).toList(growable: false),
              ),
            ),
          ),
          const SizedBox(height: SpacingToken.small),
          Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: state.groups.map((BookshelfGroupItem item) {
                      return Padding(
                        padding: const EdgeInsets.only(right: SpacingToken.small),
                        child: ChoiceChip(
                          selected: item.group.groupId == state.selectedGroupId,
                          label: Text('${item.group.groupName} ${item.bookCount}'),
                          onSelected: (bool selected) {
                            if (selected) {
                              onIntent(SelectBookshelfGroupIntent(item.group.groupId));
                            }
                          },
                        ),
                      );
                    }).toList(growable: false),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => onIntent(const ToggleBookshelfSortOrderIntent()),
                icon: Icon(state.descending ? Icons.arrow_downward : Icons.arrow_upward),
                tooltip: state.descending ? '当前倒序' : '当前正序',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 返回排序字段显示名称。
  String _sortName(BookshelfSortMode mode) {
    return switch (mode) {
      BookshelfSortMode.recentRead => '最近阅读',
      BookshelfSortMode.latestUpdate => '最新更新',
      BookshelfSortMode.name => '书名',
      BookshelfSortMode.manual => '手动顺序',
      BookshelfSortMode.recentActivity => '最近活动',
      BookshelfSortMode.author => '作者',
    };
  }
}

/// 展示刷新进度和取消结果。
final class _BookshelfRefreshStatus extends StatelessWidget {
  /// 创建刷新状态区。
  const _BookshelfRefreshStatus({required this.state, required this.onIntent});
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 构建线性进度和统计。
  @override
  Widget build(BuildContext context) {
    /// 有界进度值。
    final double? value = state.refreshProgress.total == 0
        ? null
        : state.refreshProgress.completed / state.refreshProgress.total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
      child: Column(
        children: <Widget>[
          LinearProgressIndicator(value: value),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  state.refreshCancelled
                      ? '刷新已取消'
                      : '已完成 ${state.refreshProgress.completed}/${state.refreshProgress.total}，失败 ${state.refreshProgress.failed}',
                ),
              ),
              if (state.refreshing)
                TextButton(onPressed: () => onIntent(const CancelBookshelfRefreshIntent()), child: const Text('停止')),
            ],
          ),
        ],
      ),
    );
  }
}

/// 展示单书刷新失败摘要。
final class _BookshelfRefreshFailures extends StatelessWidget {
  /// 创建失败摘要。
  const _BookshelfRefreshFailures({required this.failures});
  /// 刷新失败列表。
  final List<BookshelfRefreshFailure> failures;

  /// 构建可展开失败列表。
  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text('${failures.length} 本书刷新失败'),
      children: failures.map((BookshelfRefreshFailure failure) {
        return ListTile(dense: true, title: Text(failure.bookName), subtitle: Text(failure.message));
      }).toList(growable: false),
    );
  }
}

/// 根据状态渲染加载、空、列表或网格。
final class _BookshelfBody extends StatelessWidget {
  /// 创建书架主体。
  const _BookshelfBody({required this.state, required this.onIntent});
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 构建书架内容。
  @override
  Widget build(BuildContext context) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage != null && state.books.isEmpty) {
      return Center(child: Text(state.errorMessage ?? '书架加载失败'));
    }
    if (state.books.isEmpty) {
      return Center(child: Text(state.query.trim().isEmpty ? '书架还是空的，请先从搜索详情加入书籍' : '没有匹配的书籍'));
    }
    return state.layoutMode == BookshelfLayoutMode.list
        ? _BookshelfList(state: state, onIntent: onIntent)
        : _BookshelfGrid(state: state, onIntent: onIntent);
  }
}

/// 书架详细列表。
final class _BookshelfList extends StatelessWidget {
  /// 创建书架列表。
  const _BookshelfList({required this.state, required this.onIntent});
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 使用稳定 bookUrl key 构建列表。
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(SpacingToken.medium),
      itemCount: state.books.length,
      itemBuilder: (BuildContext context, int index) {
        /// 当前书籍显示项。
        final BookshelfBookItem item = state.books[index];
        /// 是否已选择。
        final bool selected = state.selectedBookUrls.contains(item.book.bookUrl);
        return Card(
          key: ValueKey<String>(item.book.bookUrl),
          color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
          child: ListTile(
            onTap: () => onIntent(TapBookshelfBookIntent(item.book.bookUrl)),
            onLongPress: () => onIntent(LongPressBookshelfBookIntent(item.book.bookUrl)),
            leading: SizedBox(
              width: 28,
              height: 40,
              child: BookCover(coverUrl: item.displayCoverUrl, semanticLabel: '${item.book.name}封面'),
            ),
            title: Text(item.book.name),
            subtitle: Text('${item.book.author}\n${item.book.durChapterTitle ?? item.book.latestChapterTitle ?? '尚未阅读'}'),
            isThreeLine: true,
            trailing: state.selectionMode
                ? Checkbox(
                    value: selected,
                    onChanged: (bool? value) => onIntent(TapBookshelfBookIntent(item.book.bookUrl)),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (item.unreadChapterCount > 0) Badge(label: Text('${item.unreadChapterCount}')),
                      IconButton(
                        onPressed: () => onIntent(OpenBookshelfBookInfoIntent(item.book.bookUrl)),
                        icon: const Icon(Icons.info_outline),
                        tooltip: '书籍详情',
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// 书架封面网格。
final class _BookshelfGrid extends StatelessWidget {
  /// 创建书架网格。
  const _BookshelfGrid({required this.state, required this.onIntent});
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 使用稳定 bookUrl key 构建响应式网格。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 宽屏下把封面网格约束在统一内容宽度内的水平留白。
        final double horizontalPadding = constraints.maxWidth > LayoutToken.contentMaxWidth
            ? (constraints.maxWidth - LayoutToken.contentMaxWidth) / 2
            : SpacingToken.medium;
        /// 根据实际内容宽度计算列数，至少两列且最多六列。
        final double contentWidth = constraints.maxWidth - horizontalPadding * 2;
        /// 每个书籍卡片期望占用的宽度，在上一版紧凑值上继续缩小约 30%。
        const double targetTileWidth = 88;
        /// 通过卡片左右留白缩小书籍视觉宽度，同时保持封面顶部继续铺满卡片。
        const double cardHorizontalInset = 4;
        /// 当前响应式网格列数，手机通常显示三列，宽屏最多显示十列。
        final int columns = (contentWidth / targetTileWidth).floor().clamp(3, 10).toInt();
        return GridView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: SpacingToken.medium,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: SpacingToken.small,
            mainAxisSpacing: SpacingToken.small,
            childAspectRatio: 0.64,
          ),
          itemCount: state.books.length,
          itemBuilder: (BuildContext context, int index) {
            /// 当前书籍显示项。
            final BookshelfBookItem item = state.books[index];
            /// 是否已选择。
            final bool selected = state.selectedBookUrls.contains(item.book.bookUrl);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: cardHorizontalInset),
              child: Card(
                key: ValueKey<String>(item.book.bookUrl),
                color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onIntent(TapBookshelfBookIntent(item.book.bookUrl)),
                  onLongPress: () => onIntent(LongPressBookshelfBookIntent(item.book.bookUrl)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            BookCover(coverUrl: item.displayCoverUrl, semanticLabel: '${item.book.name}封面', borderRadius: BorderRadius.zero),
                            if (item.unreadChapterCount > 0)
                              Positioned(top: 4, right: 4, child: Badge(label: Text('${item.unreadChapterCount}'))),
                            if (selected)
                              const Positioned(top: 4, left: 4, child: Icon(Icons.check_circle, size: 16)),
                            if (!state.selectionMode)
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: IconButton(
                                  onPressed: () => onIntent(OpenBookshelfBookInfoIntent(item.book.bookUrl)),
                                  icon: const Icon(Icons.info_outline, size: 16),
                                  tooltip: '书籍详情',
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(SpacingToken.xSmall),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              item.book.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Text(item.book.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
