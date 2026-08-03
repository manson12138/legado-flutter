import 'package:flutter/material.dart';

import '../../app/reader_transition_spec.dart';
import '../../model/bookshelf/bookshelf_refresh_coordinator.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'book_grid_layout.dart';
import 'bookshelf_contract.dart';

/// 读取点击瞬间封面 RenderBox 的全局矩形，不把 Context 或 RenderObject 传入阅读路由。
Rect? _bookshelfCoverGlobalRect(BuildContext? context) {
  if (context == null) {
    return null;
  }
  /// 当前封面对应的渲染对象。
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  /// 当前封面的实际布局尺寸。
  final Size size = renderObject.size;
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) {
    return null;
  }
  /// 当前封面左上角在全局坐标系中的位置。
  final Offset origin = renderObject.localToGlobal(Offset.zero);
  if (!origin.dx.isFinite || !origin.dy.isFinite) {
    return null;
  }
  return origin & size;
}

/// 只消费 BookshelfUiState 并发送 Intent 的无状态书架页面。
final class BookshelfScreen extends StatelessWidget {
  /// 创建书架纯 UI。
  const BookshelfScreen({
    required this.state,
    required this.onIntent,
    this.local = false,
    super.key,
  });

  /// ViewModel 提供的完整不可变状态。
  final BookshelfUiState state;
  /// 用户操作统一入口。
  final ValueChanged<BookshelfIntent> onIntent;
  /// 是否渲染独立本地书页签。
  final bool local;

  /// 构建高度稳定的筛选区、书籍内容和选择态悬浮操作条。
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Column(
            children: <Widget>[
              // 选择模式继续保留搜索、分组和排序区，避免内容高度突变导致书架跳动。
              _BookshelfControls(
                state: state,
                onIntent: onIntent,
                local: local,
              ),
              if (!local && (state.refreshing || state.refreshProgress.total > 0))
                _BookshelfRefreshStatus(state: state, onIntent: onIntent),
              if (state.refreshFailures.isNotEmpty)
                _BookshelfRefreshFailures(failures: state.refreshFailures),
              Expanded(
                child: _BookshelfBody(
                  state: state,
                  onIntent: onIntent,
                  local: local,
                ),
              ),
            ],
          ),
        ),
        if (state.selectionMode)
          Positioned(
            left: SpacingToken.medium,
            right: SpacingToken.medium,
            bottom: SpacingToken.small,
            child: _BookshelfSelectionActions(
              state: state,
              onIntent: onIntent,
              local: local,
            ),
          ),
      ],
    );
  }

}

/// 选择模式底部悬浮操作条，用文字和图标同时说明批量动作且不改变列表布局高度。
final class _BookshelfSelectionActions extends StatelessWidget {
  /// 创建书架选择操作条。
  const _BookshelfSelectionActions({
    required this.state,
    required this.onIntent,
    required this.local,
  });

  /// 当前选择数量和单选能力判断所需状态。
  final BookshelfUiState state;
  /// 批量操作 Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;
  /// 本地书没有联网刷新和整书换源动作。
  final bool local;

  /// 构建可横向滚动的高对比度操作面板，窄屏不会挤掉动作文字。
  @override
  Widget build(BuildContext context) {
    /// 仅选择一本书时才允许使用的单书操作。
    final bool singleSelection = state.selectedBookUrls.length == 1;
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        elevation: 8,
        borderRadius: BorderRadius.circular(RadiusToken.large),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 68,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                if (!local)
                  _BookshelfSelectionActionButton(
                    icon: Icons.refresh,
                    label: '刷新',
                    onPressed: () => onIntent(
                      const RefreshBookshelfIntent(),
                    ),
                  ),
                _BookshelfSelectionActionButton(
                  icon: Icons.drive_file_move_outline,
                  label: '分组',
                  onPressed: () => onIntent(
                    const RequestMoveBookshelfBooksIntent(),
                  ),
                ),
                _BookshelfSelectionActionButton(
                  icon: Icons.wallpaper_outlined,
                  label: '换封面',
                  onPressed: singleSelection
                      ? () => onIntent(
                          const OpenSelectedBookCoverChangeIntent(),
                        )
                      : null,
                ),
                if (!local)
                  _BookshelfSelectionActionButton(
                    icon: Icons.swap_horiz,
                    label: '换源',
                    onPressed: singleSelection
                        ? () => onIntent(
                            const OpenSelectedBookSourceChangeIntent(),
                          )
                        : null,
                  ),
                _BookshelfSelectionActionButton(
                  icon: Icons.delete_outline,
                  label: '删除',
                  destructive: true,
                  onPressed: () => onIntent(
                    const RequestDeleteBookshelfBooksIntent(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 书架选择操作条中的单个带文字动作。
final class _BookshelfSelectionActionButton extends StatelessWidget {
  /// 创建一个批量操作按钮。
  const _BookshelfSelectionActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  /// 动作图标。
  final IconData icon;
  /// 动作短标签。
  final String label;
  /// 空值表示当前选择数量不满足动作要求。
  final VoidCallback? onPressed;
  /// 是否使用错误色强调不可逆删除动作。
  final bool destructive;

  /// 构建固定最小宽度按钮，让图标与动作名称始终同时可见。
  @override
  Widget build(BuildContext context) {
    /// 删除动作使用错误色，其余动作使用主题前景色。
    final Color foreground = destructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: 70,
      height: 68,
      child: InkWell(
        onTap: onPressed,
        child: Opacity(
          opacity: onPressed == null ? 0.38 : 1,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, color: foreground, size: 22),
              const SizedBox(height: 3),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 展示搜索、分组和排序控制。
final class _BookshelfControls extends StatelessWidget {
  /// 创建控制区。
  const _BookshelfControls({
    required this.state,
    required this.onIntent,
    required this.local,
  });
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;
  /// 是否展示本地书分类。
  final bool local;

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
              hintText: local ? '搜索本地书籍' : '搜索书架',
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
                child: (local ? state.localHasManga : state.hasManga)
                    ? Row(
                  children: BookshelfContentCategory.values.map(
                    (BookshelfContentCategory category) {
                      final BookshelfContentCategory selectedCategory = local
                          ? state.selectedLocalCategory
                          : state.selectedCategory;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: SpacingToken.small),
                          child: ChoiceChip(
                            selected: category == selectedCategory,
                            label: Center(
                              child: Text(
                                category == BookshelfContentCategory.books
                                    ? '书籍'
                                    : '漫画',
                              ),
                            ),
                            onSelected: (bool selected) {
                              if (selected) {
                                onIntent(
                                  SelectBookshelfContentCategoryIntent(
                                    category: category,
                                    local: local,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      );
                    },
                  ).toList(growable: false),
                )
                    : const SizedBox.shrink(),
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
              if (!state.refreshing)
                TextButton(
                  onPressed: () => onIntent(const DismissBookshelfRefreshResultIntent()),
                  child: const Text('关闭'),
                ),
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
  const _BookshelfBody({
    required this.state,
    required this.onIntent,
    required this.local,
  });
  /// 当前状态。
  final BookshelfUiState state;
  /// Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;
  /// 是否渲染本地书集合。
  final bool local;

  /// 构建书架内容。
  @override
  Widget build(BuildContext context) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<BookshelfBookItem> books = local ? state.localBooks : state.books;
    if (state.errorMessage != null && books.isEmpty) {
      return Center(child: Text(state.errorMessage ?? '书架加载失败'));
    }
    if (books.isEmpty) {
      if (local && state.query.trim().isEmpty && !state.localHasManga) {
        return _LocalBookAddEntry(onIntent: onIntent);
      }
      if (state.query.trim().isNotEmpty) {
        return const Center(child: Text('没有匹配的书籍'));
      }
      if (local || state.hasManga) {
        return const Center(child: Text('当前分类还没有书籍'));
      }
      return const Center(child: Text('书架还是空的，请先从搜索详情加入书籍'));
    }
    final BookshelfUiState visibleState = state.copyWith(books: books);
    return state.layoutMode == BookshelfLayoutMode.list
        ? _BookshelfList(state: visibleState, onIntent: onIntent)
        : _BookshelfGrid(state: visibleState, onIntent: onIntent);
  }
}

/// 本地书为空时使用默认封面提供第二个明确导入入口。
final class _LocalBookAddEntry extends StatelessWidget {
  /// 创建本地书添加入口。
  const _LocalBookAddEntry({required this.onIntent});

  /// 页面 Intent 入口。
  final ValueChanged<BookshelfIntent> onIntent;

  /// 构建可点击的默认封面和“去添加”提示。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        onTap: () => onIntent(const OpenBookshelfLocalBookImportIntent()),
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.large),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 112,
                height: 156,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(RadiusToken.medium),
                ),
                child: const Icon(Icons.add_to_photos_outlined, size: 42),
              ),
              const SizedBox(height: SpacingToken.medium),
              const Text('去添加本地书籍'),
            ],
          ),
        ),
      ),
    );
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
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.medium,
        SpacingToken.medium,
        92,
      ),
      itemCount: state.books.length,
      itemBuilder: (BuildContext context, int index) {
        /// 当前书籍显示项。
        final BookshelfBookItem item = state.books[index];
        /// 是否已选择。
        final bool selected = state.selectedBookUrls.contains(item.book.bookUrl);
        /// 未读时沿用数字角标，全部读完后回退显示目录总章数。
        final String? chapterBadgeLabel = item.unreadChapterCount > 0
            ? '${item.unreadChapterCount}'
            : item.book.totalChapterNum > 0
                ? '共 ${item.book.totalChapterNum} 章'
                : null;
        /// 图片书籍在作者前展示明确漫画标识，普通文本书保持原排版。
        final String authorLabel = item.book.isImage
            ? '漫画 · ${item.book.author}'
            : item.book.author;
        /// 本次按下时形成的一次性封面几何，不进入状态也不跨重建保存。
        ReaderTransitionSpec? transitionSpec;
        /// 当前可见列表项中封面 Builder 的短生命周期上下文。
        BuildContext? coverContext;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (TapDownDetails _) {
            /// 点击时读取真实 leading 封面矩形，失效时让阅读路由执行中心降级。
            final Rect? sourceRect =
                _bookshelfCoverGlobalRect(coverContext);
            transitionSpec = sourceRect == null
                ? null
                : ReaderTransitionSpec.fromRect(
                    kind: ReaderTransitionKind.bookshelf,
                    coverUrl: item.displayCoverUrl,
                    sourceRect: sourceRect,
                  );
          },
          child: Card(
            key: ValueKey<String>(item.book.bookUrl),
            color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(RadiusToken.medium),
              side: selected
                  ? BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : BorderSide.none,
            ),
            child: ListTile(
              onTap: () => onIntent(
                TapBookshelfBookIntent(
                  item.book.bookUrl,
                  transitionSpec: transitionSpec,
                ),
              ),
              onLongPress: () => onIntent(LongPressBookshelfBookIntent(item.book.bookUrl)),
              leading: Builder(
                builder: (BuildContext context) {
                  coverContext = context;
                  return SizedBox(
                    width: 28,
                    height: 40,
                    child: BookCover(
                      coverUrl: item.displayCoverUrl,
                      semanticLabel: '${item.book.name}封面',
                      bookName: item.book.name,
                      bookAuthor: item.book.author,
                    ),
                  );
                },
              ),
              title: Text(item.book.name),
              subtitle: Text('$authorLabel\n${item.book.durChapterTitle ?? item.book.latestChapterTitle ?? '尚未阅读'}'),
              isThreeLine: true,
              trailing: state.selectionMode
                  ? Checkbox(
                      value: selected,
                      onChanged: (bool? value) => onIntent(TapBookshelfBookIntent(item.book.bookUrl)),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (chapterBadgeLabel != null) Badge(label: Text(chapterBadgeLabel)),
                        IconButton(
                          onPressed: () => onIntent(OpenBookshelfBookInfoIntent(item.book.bookUrl)),
                          icon: const Icon(Icons.info_outline),
                          tooltip: '书籍详情',
                        ),
                      ],
                    ),
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
        /// 当前响应式网格列数，与历史页使用相同的卡片规格。
        final int columns = (contentWidth / BookGridLayout.targetTileWidth)
            .floor()
            .clamp(BookGridLayout.minimumColumns, BookGridLayout.maximumColumns)
            .toInt();
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            SpacingToken.medium,
            horizontalPadding,
            92,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: SpacingToken.small,
            mainAxisSpacing: SpacingToken.small,
            childAspectRatio: BookGridLayout.childAspectRatio,
          ),
          itemCount: state.books.length,
          itemBuilder: (BuildContext context, int index) {
            /// 当前书籍显示项。
            final BookshelfBookItem item = state.books[index];
            /// 是否已选择。
            final bool selected = state.selectedBookUrls.contains(item.book.bookUrl);
            /// 书名字号，作为作者名和未读章节字号的换算基准。
            final double titleFontSize = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
            /// 作者名字号：比书名小 1 号。
            final double authorFontSize = titleFontSize - 1;
            /// 未读章节字号：比作者名小 2 号。
            final double unreadFontSize = authorFontSize - 2;
            /// 图片书籍在网格作者行展示明确漫画标识。
            final String authorLabel = item.book.isImage
                ? '漫画 · ${item.book.author}'
                : item.book.author;
            /// 封面底部的章节状态；全部读完时仍展示目录总章数。
            final String? chapterStatusText = item.unreadChapterCount > 0
                ? '${item.unreadChapterCount} 章未读'
                : item.book.totalChapterNum > 0
                    ? '共 ${item.book.totalChapterNum} 章'
                    : null;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: BookGridLayout.cardHorizontalInset),
              child: Card(
                key: ValueKey<String>(item.book.bookUrl),
                color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(RadiusToken.medium),
                  side: selected
                      ? BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2.5,
                        )
                      : BorderSide.none,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      // 封面区域单独响应点击：进入阅读，和下方书名作者区域的详情跳转分开。
                      child: LayoutBuilder(
                        builder: (
                          BuildContext context,
                          BoxConstraints _,
                        ) {
                          /// 本次封面按下时形成的一次性几何。
                          ReaderTransitionSpec? transitionSpec;
                          return InkWell(
                            onTapDown: (TapDownDetails _) {
                              /// 网格 LayoutBuilder 与封面区域同尺寸，直接读取真实全局矩形。
                              final Rect? sourceRect =
                                  _bookshelfCoverGlobalRect(context);
                              transitionSpec = sourceRect == null
                                  ? null
                                  : ReaderTransitionSpec.fromRect(
                                      kind:
                                          ReaderTransitionKind.bookshelf,
                                      coverUrl: item.displayCoverUrl,
                                      sourceRect: sourceRect,
                                    );
                            },
                            onTap: () => onIntent(
                              TapBookshelfBookIntent(
                                item.book.bookUrl,
                                transitionSpec: transitionSpec,
                              ),
                            ),
                            onLongPress: () => onIntent(LongPressBookshelfBookIntent(item.book.bookUrl)),
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                BookCover(
                                  coverUrl: item.displayCoverUrl,
                                  semanticLabel: '${item.book.name}封面',
                                  borderRadius: BorderRadius.zero,
                                  bookName: item.book.name,
                                  bookAuthor: item.book.author,
                                ),
                                if (state.selectionMode)
                                  Positioned(
                                    top: SpacingToken.xSmall,
                                    right: SpacingToken.xSmall,
                                    child: _BookshelfSelectionIndicator(
                                      selected: selected,
                                    ),
                                  ),
                                if (chapterStatusText != null)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: SpacingToken.xSmall,
                                        vertical: 2,
                                      ),
                                      color: Colors.white.withValues(alpha: 0.5),
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        chapterStatusText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: unreadFontSize, color: Colors.grey.shade700),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // 书名作者区域单独响应点击：正常模式下进入详情，选择模式下仍然切换选中。
                    InkWell(
                      onTap: () {
                        if (state.selectionMode) {
                          onIntent(TapBookshelfBookIntent(item.book.bookUrl));
                        } else {
                          onIntent(OpenBookshelfBookInfoIntent(item.book.bookUrl));
                        }
                      },
                      onLongPress: () => onIntent(LongPressBookshelfBookIntent(item.book.bookUrl)),
                      child: Padding(
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
                            Text(
                              authorLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(fontSize: authorFontSize),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 在书架网格封面右上角展示清晰的选中或未选中状态。
final class _BookshelfSelectionIndicator extends StatelessWidget {
  /// 创建书架选择状态标记。
  const _BookshelfSelectionIndicator({required this.selected});

  /// 当前书籍是否已经选中。
  final bool selected;

  /// 构建带阴影的强调色勾选圆或空心圆。
  @override
  Widget build(BuildContext context) {
    /// 当前主题强调色。
    final Color primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? primary : Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: primary, width: 2),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Colors.black26, blurRadius: 3),
        ],
      ),
      child: SizedBox(
        width: 28,
        height: 28,
        child: selected
            ? Icon(
                Icons.check,
                size: 19,
                color: Theme.of(context).colorScheme.onPrimary,
              )
            : null,
      ),
    );
  }
}
