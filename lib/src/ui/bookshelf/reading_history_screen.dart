import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'book_grid_layout.dart';
import 'reading_history_contract.dart';

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
    if (state.books.isEmpty) {
      return const Center(child: Text('还没有阅读历史'));
    }
    return Stack(
      children: <Widget>[
        state.layoutMode == ReadingHistoryLayoutMode.list
            ? _HistoryList(state: state, onIntent: onIntent)
            : _HistoryGrid(state: state, onIntent: onIntent),
        if (state.refreshing)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(),
          ),
      ],
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
        final Book book = state.books[index];
        return Card(
          key: ValueKey<String>('history-${book.bookUrl}'),
          child: ListTile(
            onTap: () => onIntent(OpenReadingHistoryBookIntent(book.bookUrl)),
            leading: SizedBox(
              width: 36,
              height: 50,
              child: _HistoryCover(book: book),
            ),
            title: Text(book.name),
            subtitle: Text('${book.author}\n${book.durChapterTitle ?? '已阅读'}'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
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
            final Book book = state.books[index];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: BookGridLayout.cardHorizontalInset),
              child: Card(
                key: ValueKey<String>('history-grid-${book.bookUrl}'),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onIntent(OpenReadingHistoryBookIntent(book.bookUrl)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: _HistoryCover(book: book)),
                      Padding(
                        padding: const EdgeInsets.all(SpacingToken.xSmall),
                        child: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
