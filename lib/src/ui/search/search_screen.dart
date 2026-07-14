import 'package:flutter/material.dart';

import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'search_contract.dart';

/// 只渲染搜索状态并发送 Intent 的无状态页面。
final class SearchScreen extends StatelessWidget {
  /// 创建搜索纯 UI。
  const SearchScreen({required this.state, required this.onIntent, super.key});

  /// ViewModel 提供的不可变状态。
  final SearchUiState state;

  /// 用户操作统一入口。
  final ValueChanged<SearchIntent> onIntent;

  /// 构建搜索输入、筛选、进度、错误和增量结果。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => onIntent(const BackFromSearchIntent()),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
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

/// 展示单源失败摘要和重试入口。
final class _SearchFailures extends StatelessWidget {
  /// 创建失败区域。
  const _SearchFailures({required this.state, required this.onIntent});
  /// 当前状态。
  final SearchUiState state;
  /// Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  /// 构建错误摘要卡片。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(SpacingToken.medium),
      child: Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ExpansionTile(
          title: Text('${state.failures.length} 个书源失败'),
          trailing: TextButton(
            onPressed: state.searching ? null : () => onIntent(const RetryFailedSourcesIntent()),
            child: const Text('重试失败项'),
          ),
          children: state.failures.map((BookSearchSourceFailure failure) {
            return ListTile(
              dense: true,
              title: Text(failure.sourceName),
              subtitle: Text('${failure.category}：${failure.message}'),
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
    return ListView.separated(
      padding: const EdgeInsets.all(SpacingToken.medium),
      itemCount: state.results.length,
      separatorBuilder: (BuildContext context, int index) => const SizedBox(height: SpacingToken.small),
      itemBuilder: (BuildContext context, int index) {
        /// 当前稳定结果组。
        final BookSearchResultGroup group = state.results[index];
        return Card(
          key: ValueKey<String>(group.key),
          child: ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(group.primary.name),
            subtitle: Text('${group.primary.author}\n${group.primary.originName} · ${group.books.length} 个来源'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onIntent(OpenSearchResultIntent(group, group.primary)),
          ),
        );
      },
    );
  }
}
