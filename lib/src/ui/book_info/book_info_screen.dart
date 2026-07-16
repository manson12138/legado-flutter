import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/search_book.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'book_info_contract.dart';

/// 只渲染详情和目录状态并发送 Intent 的无状态页面。
final class BookInfoScreen extends StatelessWidget {
  /// 创建详情纯 UI。
  const BookInfoScreen({required this.state, required this.onIntent, super.key});
  /// ViewModel 提供的不可变状态。
  final BookInfoUiState state;
  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建详情、换源、目录预览和加入书架操作。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => onIntent(const BackFromBookInfoIntent()),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        title: Text(state.book?.name ?? state.selectedBook.name),
        actions: <Widget>[
          if (state.group.books.length > 1)
            PopupMenuButton<SearchBook>(
              tooltip: '更换书源',
              icon: const Icon(Icons.swap_horiz),
              onSelected: (SearchBook book) => onIntent(ChangeBookInfoSourceIntent(book)),
              itemBuilder: (BuildContext context) => state.group.books.map((SearchBook book) {
                return CheckedPopupMenuItem<SearchBook>(
                  value: book,
                  checked: book.origin == state.selectedBook.origin && book.bookUrl == state.selectedBook.bookUrl,
                  child: Text(book.originName),
                );
              }).toList(growable: false),
            ),
        ],
      ),
      body: _BookInfoBody(state: state, onIntent: onIntent),
      floatingActionButton: state.book == null
          ? null
          : FloatingActionButton.extended(
              onPressed: state.addingToShelf ||
                      state.inBookshelf ||
                      state.loadingToc ||
                      state.tocError != null ||
                      state.chapters.isEmpty
                  ? null
                  : () => onIntent(const AddBookToShelfIntent()),
              icon: Icon(state.inBookshelf ? Icons.check : Icons.add),
              label: Text(state.inBookshelf ? '已在书架' : state.addingToShelf ? '正在加入' : '加入书架'),
            ),
    );
  }
}

/// 根据详情加载状态构建页面主体。
final class _BookInfoBody extends StatelessWidget {
  /// 创建详情主体。
  const _BookInfoBody({required this.state, required this.onIntent});
  /// 当前状态。
  final BookInfoUiState state;
  /// Intent 入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建加载、错误或详情内容。
  @override
  Widget build(BuildContext context) {
    if (state.loadingInfo) {
      return const Center(child: CircularProgressIndicator());
    }
    /// 已解析书籍。
    final Book? book = state.book;
    if (book == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(state.infoError ?? '详情加载失败'),
            const SizedBox(height: SpacingToken.medium),
            FilledButton(onPressed: () => onIntent(const RetryBookInfoIntent()), child: const Text('重试详情')),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.medium,
        SpacingToken.medium,
        104,
      ),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(SpacingToken.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(book.name, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: SpacingToken.small),
                Text('作者：${book.author.isEmpty ? '未知' : book.author}'),
                Text('来源：${book.originName}'),
                if (book.kind?.isNotEmpty == true) Text('分类：${book.kind}'),
                if (book.wordCount?.isNotEmpty == true) Text('字数：${book.wordCount}'),
                if (book.latestChapterTitle?.isNotEmpty == true) Text('最新：${book.latestChapterTitle}'),
                const SizedBox(height: SpacingToken.medium),
                Text(book.intro?.trim().isNotEmpty == true ? book.intro ?? '' : '暂无简介'),
              ],
            ),
          ),
        ),
        const SizedBox(height: SpacingToken.medium),
        Row(
          children: <Widget>[
            Text('目录（${state.chapters.length}）', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (state.loadingToc) const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            if (!state.loadingToc && state.tocError != null)
              TextButton(onPressed: () => onIntent(const RetryBookTocIntent()), child: const Text('重试目录')),
          ],
        ),
        if (state.tocError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: SpacingToken.small),
            child: Text(state.tocError ?? '目录加载失败', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (!state.loadingToc && state.chapters.isEmpty && state.tocError == null)
          const Padding(padding: EdgeInsets.all(SpacingToken.large), child: Center(child: Text('暂无目录'))),
        ...state.chapters.asMap().entries.map((MapEntry<int, BookChapter> entry) {
          /// 当前目录项在页面完整目录中的稳定位置。
          final int chapterIndex = entry.key;
          /// 当前目录项对应的章节对象。
          final BookChapter chapter = entry.value;
          return ListTile(
            key: ValueKey<String>('${chapter.index}:${chapter.url}'),
            dense: true,
            leading: Text('${chapter.index + 1}'),
            title: Text(chapter.title),
            subtitle: chapter.tag == null ? null : Text(chapter.tag ?? ''),
            enabled: !chapter.isVolume && !state.addingToShelf,
            onTap: chapter.isVolume || state.addingToShelf
                ? null
                : () => onIntent(OpenBookInfoChapterIntent(chapterIndex)),
          );
        }),
      ],
    );
  }
}
