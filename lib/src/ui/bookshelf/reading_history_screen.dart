import 'package:flutter/material.dart';

import '../../app/reader_transition_spec.dart';
import '../../domain/model/book.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'book_grid_layout.dart';
import 'reading_history_contract.dart';

/// 读取历史 cell 中封面的真实全局矩形，只把不可变 Rect 交给阅读路由。
Rect? _historyCoverGlobalRect(BuildContext? context) {
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
  /// 当前封面左上角的全局位置。
  final Offset origin = renderObject.localToGlobal(Offset.zero);
  if (!origin.dx.isFinite || !origin.dy.isFinite) {
    return null;
  }
  return origin & size;
}

/// 展示所有已成功阅读书籍的独立历史内容页。
final class ReadingHistoryScreen extends StatelessWidget {
  /// 创建历史纯 UI。
  const ReadingHistoryScreen({
    required this.state,
    required this.onIntent,
    super.key,
  });

  /// 历史页面状态。
  final ReadingHistoryUiState state;
  /// 历史操作入口。
  final ValueChanged<ReadingHistoryIntent> onIntent;

  /// 构建位于固定顶部下方、可随 PageView 横滑的历史内容。
  @override
  Widget build(BuildContext context) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage != null && state.books.isEmpty) {
      return Center(child: Text(state.errorMessage ?? '阅读历史加载失败'));
    }
    if (state.books.isEmpty && !state.hasManga) {
      return const Center(child: Text('还没有阅读历史'));
    }
    return Column(
      children: <Widget>[
        if (state.hasManga)
          _HistoryContentCategories(state: state, onIntent: onIntent),
        Expanded(
          child: Stack(
            children: <Widget>[
              if (state.books.isEmpty)
                const Center(child: Text('当前分类还没有阅读历史'))
              else if (state.layoutMode == ReadingHistoryLayoutMode.list)
                _HistoryList(state: state, onIntent: onIntent)
              else
                _HistoryGrid(state: state, onIntent: onIntent),
              if (state.refreshing)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 历史中确实存在漫画时展示两个等宽分类。
final class _HistoryContentCategories extends StatelessWidget {
  /// 创建历史分类栏。
  const _HistoryContentCategories({required this.state, required this.onIntent});

  /// 当前分类状态。
  final ReadingHistoryUiState state;
  /// 历史 Intent 入口。
  final ValueChanged<ReadingHistoryIntent> onIntent;

  /// 构建书籍和漫画两个等宽按钮。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.small,
        SpacingToken.medium,
        0,
      ),
      child: Row(
        children: ReadingHistoryContentCategory.values.map(
          (ReadingHistoryContentCategory category) => Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: SpacingToken.small),
              child: ChoiceChip(
                selected: state.selectedCategory == category,
                label: Center(
                  child: Text(
                    category == ReadingHistoryContentCategory.books
                        ? '书籍'
                        : '漫画',
                  ),
                ),
                onSelected: (bool selected) {
                  if (selected) {
                    onIntent(SelectReadingHistoryContentCategoryIntent(category));
                  }
                },
              ),
            ),
          ),
        ).toList(growable: false),
      ),
    );
  }
}

/// 历史书籍单列详情列表。
final class _HistoryList extends StatelessWidget {
  /// 创建历史列表。
  const _HistoryList({required this.state, required this.onIntent});

  /// 当前历史状态。
  final ReadingHistoryUiState state;
  /// 页面操作入口。
  final ValueChanged<ReadingHistoryIntent> onIntent;

  /// 构建惰性历史列表。
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(SpacingToken.medium),
      itemCount: state.books.length,
      itemBuilder: (BuildContext context, int index) {
        /// 当前历史书籍。
        final Book book = state.books[index];
        /// 当前历史列表项是否已被选中。
        final bool selected = state.selectedBookUrls.contains(book.bookUrl);
        /// 本次按下时形成的一次性封面几何。
        ReaderTransitionSpec? transitionSpec;
        /// 当前可见历史列表项中封面 Builder 的短生命周期上下文。
        BuildContext? coverContext;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (TapDownDetails _) {
            /// 点击时读取真实 leading 封面矩形，失效时由阅读路由中心降级。
            final Rect? sourceRect = _historyCoverGlobalRect(coverContext);
            transitionSpec = sourceRect == null
                ? null
                : ReaderTransitionSpec.fromRect(
                    kind: ReaderTransitionKind.history,
                    coverUrl: book.customCoverUrl ?? book.coverUrl,
                    sourceRect: sourceRect,
                  );
          },
          child: Card(
            key: ValueKey<String>('history-${book.bookUrl}'),
            color: selected
                ? Theme.of(context).colorScheme.secondaryContainer
                : null,
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
                OpenReadingHistoryBookIntent(
                  book.bookUrl,
                  transitionSpec: transitionSpec,
                ),
              ),
              onLongPress: () => onIntent(
                LongPressReadingHistoryBookIntent(book.bookUrl),
              ),
              leading: Builder(
                builder: (BuildContext context) {
                  coverContext = context;
                  return SizedBox(
                    width: 36,
                    height: 50,
                    child: _HistoryCover(book: book),
                  );
                },
              ),
              title: Text(book.name),
              subtitle: Text('${book.author}\n${book.durChapterTitle ?? '已阅读'}'),
              isThreeLine: true,
              trailing: state.selectionMode
                  ? Checkbox(
                      value: selected,
                      onChanged: (bool? value) => onIntent(
                        OpenReadingHistoryBookIntent(book.bookUrl),
                      ),
                    )
                  : const Icon(Icons.chevron_right),
            ),
          ),
        );
      },
    );
  }
}

/// 历史书籍封面网格。
final class _HistoryGrid extends StatelessWidget {
  /// 创建历史网格。
  const _HistoryGrid({required this.state, required this.onIntent});

  /// 当前历史状态。
  final ReadingHistoryUiState state;
  /// 页面操作入口。
  final ValueChanged<ReadingHistoryIntent> onIntent;

  /// 构建按可用宽度自适应列数的惰性网格。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 宽屏下限制内容宽度，与书架保持相同的书籍卡片实际宽度。
        final double horizontalPadding = constraints.maxWidth > LayoutToken.contentMaxWidth
            ? (constraints.maxWidth - LayoutToken.contentMaxWidth) / 2
            : SpacingToken.medium;
        /// 扣除水平留白后用于计算统一网格列数的内容宽度。
        final double contentWidth = constraints.maxWidth - horizontalPadding * 2;
        /// 使用与书架一致的可用宽度和列数计算规则。
        final int columns = (contentWidth / BookGridLayout.targetTileWidth)
            .floor()
            .clamp(BookGridLayout.minimumColumns, BookGridLayout.maximumColumns)
            .toInt();
        return GridView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: SpacingToken.medium,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: SpacingToken.small,
            mainAxisSpacing: SpacingToken.small,
            childAspectRatio: BookGridLayout.childAspectRatio,
          ),
          itemCount: state.books.length,
          itemBuilder: (BuildContext context, int index) {
            /// 当前历史书籍。
            final Book book = state.books[index];
            /// 当前历史网格项是否已被选中。
            final bool selected = state.selectedBookUrls.contains(book.bookUrl);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: BookGridLayout.cardHorizontalInset),
              child: Card(
                key: ValueKey<String>('history-grid-${book.bookUrl}'),
                color: selected
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
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
                                  _historyCoverGlobalRect(context);
                              transitionSpec = sourceRect == null
                                  ? null
                                  : ReaderTransitionSpec.fromRect(
                                      kind: ReaderTransitionKind.history,
                                      coverUrl:
                                          book.customCoverUrl ??
                                          book.coverUrl,
                                      sourceRect: sourceRect,
                                    );
                            },
                            onTap: () => onIntent(
                              OpenReadingHistoryBookIntent(
                                book.bookUrl,
                                transitionSpec: transitionSpec,
                              ),
                            ),
                            onLongPress: () => onIntent(
                              LongPressReadingHistoryBookIntent(book.bookUrl),
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                _HistoryCover(book: book),
                                if (state.selectionMode)
                                  Positioned(
                                    top: SpacingToken.xSmall,
                                    right: SpacingToken.xSmall,
                                    child: _HistorySelectionIndicator(
                                      selected: selected,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    InkWell(
                      onTap: () => onIntent(
                        OpenReadingHistoryBookIntent(book.bookUrl),
                      ),
                      onLongPress: () => onIntent(
                        LongPressReadingHistoryBookIntent(book.bookUrl),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(SpacingToken.xSmall),
                        child: Text(
                          book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

/// 在历史网格封面右上角明确展示选中或未选中的圆形状态。
final class _HistorySelectionIndicator extends StatelessWidget {
  /// 创建历史选择状态标记。
  const _HistorySelectionIndicator({required this.selected});

  /// 当前书籍是否已经选中。
  final bool selected;

  /// 构建高对比度勾选圆或未选中空心圆。
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
        width: 26,
        height: 26,
        child: selected
            ? Icon(
                Icons.check,
                size: 18,
                color: Theme.of(context).colorScheme.onPrimary,
              )
            : null,
      ),
    );
  }
}

/// 复用统一封面组件渲染历史书籍。
final class _HistoryCover extends StatelessWidget {
  /// 创建历史封面。
  const _HistoryCover({required this.book});

  /// 历史书籍快照。
  final Book book;

  /// 构建封面。
  @override
  Widget build(BuildContext context) {
    return BookCover(
      coverUrl: book.customCoverUrl ?? book.coverUrl,
      semanticLabel: '${book.name}封面',
      borderRadius: BorderRadius.zero,
      bookName: book.name,
      bookAuthor: book.author,
    );
  }
}
