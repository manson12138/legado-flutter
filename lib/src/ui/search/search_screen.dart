import 'package:flutter/material.dart';

import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../components/app_scaffold.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'search_contract.dart';

/// 只渲染搜索状态并发送 Intent 的无状态页面。
final class SearchScreen extends StatelessWidget {
  /// 创建搜索纯 UI。
  const SearchScreen({
    required this.state,
    required this.onIntent,
    this.showBackButton = true,
    super.key,
  });

  /// ViewModel 提供的不可变状态。
  final SearchUiState state;

  /// 用户操作统一入口。
  final ValueChanged<SearchIntent> onIntent;

  /// 顶部栏是否展示返回按钮。
  final bool showBackButton;

  /// 构建搜索输入、筛选、进度、错误和增量结果。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: showBackButton
            ? IconButton(
                onPressed: () => onIntent(const BackFromSearchIntent()),
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
              )
            : null,
        title: const Text('搜索书籍'),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: '选择搜索书源',
            icon: const Icon(Icons.filter_alt_outlined),
            onSelected: (String value) {
              if (value == '__all__') {
                onIntent(const SelectAllSearchSourcesIntent());
              } else {
                onIntent(ToggleSearchSourceIntent(value));
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: '__all__',
                checked: state.selectedSourceUrls.isEmpty,
                child: const Text('全部启用书源'),
              ),
              ...state.sources.map((BookSource source) {
                return CheckedPopupMenuItem<String>(
                  value: source.bookSourceUrl,
                  checked: state.selectedSourceUrls.isEmpty || state.selectedSourceUrls.contains(source.bookSourceUrl),
                  child: Text(source.bookSourceName),
                );
              }),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(SpacingToken.medium),
            child: TextFormField(
              key: ValueKey<String>('search-${state.committedKeyword}'),
              initialValue: state.keyword,
              textInputAction: TextInputAction.search,
              onChanged: (String value) => onIntent(ChangeSearchKeywordIntent(value)),
              onFieldSubmitted: (String value) => onIntent(SubmitSearchIntent(keyword: value)),
              decoration: InputDecoration(
                labelText: '书名或作者',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: state.searching
                    ? IconButton(
                        onPressed: () => onIntent(const CancelSearchIntent()),
                        icon: const Icon(Icons.stop_circle_outlined),
                        tooltip: '停止搜索',
                      )
                    : IconButton(
                        onPressed: () => onIntent(const SubmitSearchIntent()),
                        icon: const Icon(Icons.arrow_forward),
                        tooltip: '开始搜索',
                      ),
              ),
            ),
          ),
          if (state.history.isNotEmpty && state.committedKeyword.isEmpty)
            _SearchHistory(state: state, onIntent: onIntent),
          if (state.searching || state.progress.total > 0)
            _SearchProgress(state: state),
          if (state.failures.isNotEmpty)
            _SearchFailures(state: state, onIntent: onIntent),
          Expanded(child: _SearchBody(state: state, onIntent: onIntent)),
        ],
      ),
    );
  }
}

/// 展示最近搜索关键字。
final class _SearchHistory extends StatelessWidget {
  /// 创建历史区域。
  const _SearchHistory({required this.state, required this.onIntent});
  /// 当前状态。
  final SearchUiState state;
  /// Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  /// 构建可点击历史标签。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('最近搜索', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton(onPressed: () => onIntent(const ClearSearchHistoryIntent()), child: const Text('清空')),
            ],
          ),
          Wrap(
            spacing: SpacingToken.small,
            children: state.history.map((String keyword) {
              return ActionChip(
                label: Text(keyword),
                onPressed: () => onIntent(SubmitSearchIntent(keyword: keyword)),
              );
            }).toList(growable: false),
          ),
        ],
      ),
    );
  }
}

/// 展示受控搜索进度。
final class _SearchProgress extends StatelessWidget {
  /// 创建进度区域。
  const _SearchProgress({required this.state});
  /// 当前状态。
  final SearchUiState state;

  /// 构建线性进度和统计。
  @override
  Widget build(BuildContext context) {
    /// 防止总数为零产生除零的进度值。
    final double? value = state.progress.total == 0
        ? null
        : state.progress.completed / state.progress.total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
      child: Column(
        children: <Widget>[
          LinearProgressIndicator(value: value),
          const SizedBox(height: SpacingToken.small),
          Text(
            state.cancelled
                ? '已停止，保留已完成结果'
                : '书源 ${state.progress.completed}/${state.progress.total}，失败 ${state.progress.failed}',
          ),
        ],
      ),
    );
  }
}

/// 展示单源失败摘要和重试入口；只作为辅助信息，不与正常结果争抢注意力。
final class _SearchFailures extends StatelessWidget {
  /// 创建失败区域。
  const _SearchFailures({required this.state, required this.onIntent});
  /// 当前状态。
  final SearchUiState state;
  /// Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  /// 构建弱化的失败摘要，用中性小字代替醒目的错误色卡片。
  @override
  Widget build(BuildContext context) {
    /// 当前配色，弱化文字统一使用次要前景色。
    final ColorScheme scheme = Theme.of(context).colorScheme;
    /// 弱化文字样式。
    final TextStyle? mutedStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          collapsedIconColor: scheme.onSurfaceVariant,
          iconColor: scheme.onSurfaceVariant,
          title: Text('${state.failures.length} 个书源未返回结果', style: mutedStyle),
          trailing: TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: SpacingToken.small),
            ),
            onPressed: state.searching ? null : () => onIntent(const RetryFailedSourcesIntent()),
            child: const Text('重试'),
          ),
          children: state.failures.map((BookSearchSourceFailure failure) {
            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(failure.sourceName, style: Theme.of(context).textTheme.bodySmall),
              subtitle: Text('${failure.category}：${failure.message}', style: mutedStyle),
            );
          }).toList(growable: false),
        ),
      ),
    );
  }
}

/// 根据状态渲染加载、空、失败或结果列表。
final class _SearchBody extends StatelessWidget {
  /// 创建搜索主体。
  const _SearchBody({required this.state, required this.onIntent});
  /// 当前状态。
  final SearchUiState state;
  /// Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  /// 构建状态主体。
  @override
  Widget build(BuildContext context) {
    if (state.loadingSources) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage != null && state.results.isEmpty) {
      return Center(child: Text(state.errorMessage ?? '搜索失败'));
    }
    if (state.committedKeyword.isEmpty) {
      return const Center(child: Text('输入书名或作者，从已启用书源中搜索'));
    }
    if (state.results.isEmpty && state.searching) {
      return const Center(child: Text('正在等待首个书源结果…'));
    }
    if (state.results.isEmpty) {
      return Center(child: Text(state.failures.isEmpty ? '没有找到结果' : '全部书源均未返回可用结果'));
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 宽屏下把结果约束在舒适阅读宽度内的水平留白。
        final double horizontalPadding = constraints.maxWidth > LayoutToken.contentMaxWidth
            ? (constraints.maxWidth - LayoutToken.contentMaxWidth) / 2
            : SpacingToken.medium;
        return ListView.separated(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: SpacingToken.small,
          ),
          itemCount: state.results.length,
          separatorBuilder: (BuildContext context, int index) => const Divider(),
          itemBuilder: (BuildContext context, int index) {
            /// 当前稳定结果组。
            final BookSearchResultGroup group = state.results[index];
            return Material(
              key: ValueKey<String>(group.key),
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onIntent(OpenSearchResultIntent(group, group.primary)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: SpacingToken.small),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 35,
                        height: 51,
                        child: _SearchResultCover(group: group),
                      ),
                      const SizedBox(width: SpacingToken.mediumSmall),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              group.primary.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              group.primary.author.isEmpty ? '未知作者' : group.primary.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: SpacingToken.xSmall),
                            Text(
                              '${group.primary.originName} · ${group.books.length} 个来源',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
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

/// 依次尝试候选组内多个来源的封面地址，某个地址显示不出来时自动换下一个同名候选的封面。
final class _SearchResultCover extends StatefulWidget {
  /// 创建候选组封面。
  const _SearchResultCover({required this.group});

  /// 当前同名同作者候选组。
  final BookSearchResultGroup group;

  /// 创建尝试进度状态。
  @override
  State<_SearchResultCover> createState() => _SearchResultCoverState();
}

/// 持有当前尝试到第几个候选地址。
final class _SearchResultCoverState extends State<_SearchResultCover> {
  /// 当前正在尝试的候选下标。
  int _index = 0;

  /// 候选组切换（例如重新提交搜索）时重置尝试进度。
  @override
  void didUpdateWidget(covariant _SearchResultCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.key != widget.group.key) {
      _index = 0;
    }
  }

  /// 按候选组结果顺序去重后的可用封面地址。
  List<String> _candidateUrls() {
    /// 已经出现过的地址，避免重复尝试同一张图。
    final Set<String> seen = <String>{};
    /// 去重后的候选地址。
    final List<String> urls = <String>[];
    for (final SearchBook book in widget.group.books) {
      /// 当前候选来源的封面地址。
      final String url = book.coverUrl?.trim() ?? '';
      if (url.isNotEmpty && seen.add(url)) {
        urls.add(url);
      }
    }
    return urls;
  }

  /// 依次尝试候选地址；组内全部失败后交给 [BookCover] 自身的跨页面缓存兜底。
  @override
  Widget build(BuildContext context) {
    /// 当前候选组内可尝试的全部封面地址。
    final List<String> candidates = _candidateUrls();
    /// 候选组书名，用于无障碍说明和缓存 key。
    final String bookName = widget.group.primary.name;
    /// 候选组作者，用于缓存 key。
    final String bookAuthor = widget.group.primary.author;
    /// 无障碍封面说明。
    final String semanticLabel = '$bookName封面';
    if (_index >= candidates.length) {
      return BookCover(
        coverUrl: null,
        semanticLabel: semanticLabel,
        bookName: bookName,
        bookAuthor: bookAuthor,
      );
    }
    /// 本次尝试的候选下标，供 onExhausted 回调核对是否仍然有效。
    final int attemptIndex = _index;
    return BookCover(
      key: ValueKey<String>(candidates[attemptIndex]),
      coverUrl: candidates[attemptIndex],
      semanticLabel: semanticLabel,
      bookName: bookName,
      bookAuthor: bookAuthor,
      onExhausted: () {
        if (!mounted || _index != attemptIndex) {
          return;
        }
        setState(() => _index = attemptIndex + 1);
      },
    );
  }
}
