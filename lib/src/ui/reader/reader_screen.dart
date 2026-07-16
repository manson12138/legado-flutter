import 'package:flutter/material.dart';

import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';

/// 只消费 ReaderUiState、滚动控制器并发送 Intent 的无状态上下滚动阅读页面。
final class ReaderScreen extends StatelessWidget {
  /// 创建阅读器纯 UI。
  const ReaderScreen({
    required this.state,
    required this.onIntent,
    required this.scrollController,
    super.key,
  });

  /// ViewModel 提供的完整不可变状态。
  final ReaderUiState state;

  /// 用户操作统一入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 路由层持有的瞬时滚动控制器，不进入业务 UiState。
  final ScrollController scrollController;

  /// 构建可隐藏菜单、惰性正文和章节控制栏。
  @override
  Widget build(BuildContext context) {
    /// 阅读背景色。
    final Color backgroundColor = Color(state.config.backgroundColorValue);
    return AppScaffold(
      appBar: state.menuVisible ? _buildAppBar(context) : null,
      bottomNavigationBar: state.menuVisible ? _buildBottomBar(context) : null,
      body: ColoredBox(
        color: backgroundColor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => onIntent(const ToggleReaderMenuIntent()),
          child: _buildBody(context),
        ),
      ),
    );
  }

  /// 构建返回、章节标题、书签和设置入口。
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    /// 当前章节标题。
    final String title = state.currentChapter?.title ?? state.book?.name ?? '阅读';
    return AppBar(
      backgroundColor: Color(state.config.backgroundColorValue),
      foregroundColor: Color(state.config.textColorValue),
      leading: IconButton(
        onPressed: () => onIntent(const CloseReaderIntent()),
        icon: const Icon(Icons.arrow_back),
        tooltip: '返回书架',
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: <Widget>[
        IconButton(
          onPressed: state.book == null || state.book?.origin == 'loc_book'
              ? null
              : () => onIntent(const OpenReaderBookSourceChangeIntent()),
          icon: const Icon(Icons.swap_horiz),
          tooltip: '整书换源',
        ),
        IconButton(
          onPressed: state.loadState == ReaderLoadState.ready
              ? () => onIntent(const AddReaderBookmarkIntent())
              : null,
          icon: const Icon(Icons.bookmark_add_outlined),
          tooltip: '添加书签',
        ),
        IconButton(
          onPressed: () => onIntent(const ShowReaderSheetIntent(ReaderSettingsSheet())),
          icon: const Icon(Icons.text_fields),
          tooltip: '显示设置',
        ),
      ],
    );
  }

  /// 根据加载状态构建初始化、错误或惰性正文列表。
  Widget _buildBody(BuildContext context) {
    return switch (state.loadState) {
      ReaderLoadState.initializing || ReaderLoadState.loading => const Center(
        child: CircularProgressIndicator(),
      ),
      ReaderLoadState.error => _ReaderErrorBody(
        message: state.errorMessage ?? '章节正文加载失败',
        onRetry: () => onIntent(const RetryReaderChapterIntent()),
      ),
      ReaderLoadState.ready => _ReaderContentList(
        state: state,
        scrollController: scrollController,
        onIntent: onIntent,
      ),
    };
  }

  /// 构建上一章、目录、书签和下一章控制栏。
  Widget _buildBottomBar(BuildContext context) {
    return BottomAppBar(
      color: Color(state.config.backgroundColorValue),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          IconButton(
            onPressed: state.canGoPrevious
                ? () => onIntent(const OpenPreviousChapterIntent())
                : null,
            icon: const Icon(Icons.skip_previous),
            tooltip: '上一章',
          ),
          IconButton(
            onPressed: () => onIntent(const ShowReaderSheetIntent(ReaderTocSheet())),
            icon: const Icon(Icons.format_list_numbered),
            tooltip: '目录',
          ),
          IconButton(
            onPressed: () => onIntent(const ShowReaderSheetIntent(ReaderBookmarksSheet())),
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '书签',
          ),
          IconButton(
            onPressed: state.canGoNext
                ? () => onIntent(const OpenNextChapterIntent())
                : null,
            icon: const Icon(Icons.skip_next),
            tooltip: '下一章',
          ),
        ],
      ),
    );
  }
}

/// 展示明确错误和强制刷新重试入口。
final class _ReaderErrorBody extends StatelessWidget {
  /// 创建阅读错误视图。
  const _ReaderErrorBody({required this.message, required this.onRetry});

  /// 用户可见错误摘要。
  final String message;

  /// 重试回调。
  final VoidCallback onRetry;

  /// 构建居中错误状态。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.large),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.menu_book_outlined, size: 48),
            const SizedBox(height: SpacingToken.medium),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: SpacingToken.medium),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新获取正文'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 使用 ListView.builder 惰性排版有限正文块，并把滚动比例换算为稳定字符位置。
final class _ReaderContentList extends StatelessWidget {
  /// 创建惰性正文列表。
  const _ReaderContentList({
    required this.state,
    required this.scrollController,
    required this.onIntent,
  });

  /// 当前阅读状态。
  final ReaderUiState state;

  /// 路由层滚动控制器。
  final ScrollController scrollController;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 构建章节标题和正文分块，并监听用户滚动。
  @override
  Widget build(BuildContext context) {
    /// 当前正文结果。
    final content = state.content;
    if (content == null) {
      return const SizedBox.shrink();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification.metrics.axis != Axis.vertical || content.text.isEmpty) {
          return false;
        }
        /// 当前可滚动范围比例，仅用于把布局位置换算为字符锚点，不持久化像素。
        final double progress = notification.metrics.maxScrollExtent <= 0
            ? 0
            : (notification.metrics.pixels / notification.metrics.maxScrollExtent)
                  .clamp(0, 1)
                  .toDouble();
        /// 章节内稳定字符位置。
        final int characterOffset = (progress * mathMax(0, content.text.length - 1)).round();
        onIntent(UpdateReaderScrollIntent(characterOffset));
        return false;
      },
      child: ListView.builder(
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(
          state.config.horizontalPadding,
          SpacingToken.large,
          state.config.horizontalPadding,
          SpacingToken.xLarge,
        ),
        itemCount: content.blocks.length + 2,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: SpacingToken.large),
              child: Text(
                content.title,
                style: TextStyle(
                  color: Color(state.config.textColorValue),
                  fontSize: state.config.fontSize + 6,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            );
          }
          if (index == content.blocks.length + 1) {
            return _ChapterEndActions(state: state, onIntent: onIntent);
          }
          /// 当前稳定正文块。
          final block = content.blocks[index - 1];
          return Padding(
            key: ValueKey<String>(block.id),
            padding: EdgeInsets.only(bottom: state.config.paragraphSpacing),
            child: Text(
              block.text,
              style: TextStyle(
                color: Color(state.config.textColorValue),
                fontSize: state.config.fontSize,
                height: state.config.lineHeight,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 返回两个整数的较大值，避免仅为一个表达式引入业务无关依赖。
  int mathMax(int left, int right) => left > right ? left : right;
}

/// 展示章末状态和连续阅读入口。
final class _ChapterEndActions extends StatelessWidget {
  /// 创建章末操作区。
  const _ChapterEndActions({required this.state, required this.onIntent});

  /// 当前阅读状态。
  final ReaderUiState state;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 构建缓存来源、替换统计和下一章按钮。
  @override
  Widget build(BuildContext context) {
    /// 当前正文结果。
    final content = state.content;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SpacingToken.large),
      child: Column(
        children: <Widget>[
          Divider(color: Color(state.config.textColorValue).withValues(alpha: 0.25)),
          Text(
            content?.fromCache == true ? '本章来自正文缓存' : '本章来自书源请求',
            style: TextStyle(color: Color(state.config.textColorValue).withValues(alpha: 0.65)),
          ),
          if ((content?.effectiveReplaceRuleCount ?? 0) > 0)
            Text(
              '已应用 ${content?.effectiveReplaceRuleCount ?? 0} 条替换规则',
              style: TextStyle(color: Color(state.config.textColorValue).withValues(alpha: 0.65)),
            ),
          const SizedBox(height: SpacingToken.medium),
          FilledButton.tonalIcon(
            onPressed: state.canGoNext
                ? () => onIntent(const OpenNextChapterIntent())
                : null,
            icon: const Icon(Icons.arrow_forward),
            label: Text(state.canGoNext ? '阅读下一章' : '已到最后一章'),
          ),
        ],
      ),
    );
  }
}
