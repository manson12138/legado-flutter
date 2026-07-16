import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../components/app_scaffold.dart';
import '../components/app_state_views.dart';
import '../theme/app_tokens.dart';
import 'change_book_source_contract.dart';

/// 只消费 UiState 并发送 Intent 的整书换源无状态页面。
final class ChangeBookSourceScreen extends StatelessWidget {
  /// 创建整书换源纯 UI。
  const ChangeBookSourceScreen({
    required this.state,
    required this.onIntent,
    super.key,
  });

  /// ViewModel 提供的完整不可变状态。
  final ChangeBookSourceUiState state;

  /// 页面所有用户操作的统一 Intent 入口。
  final ValueChanged<ChangeBookSourceIntent> onIntent;

  /// 构建顶部栏、初始化状态和可滚动换源内容。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => onIntent(const BackFromChangeBookSourceIntent()),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        title: const Text('整书换源'),
        actions: <Widget>[
          IconButton(
            onPressed: state.initializing || state.oldBook == null
                ? null
                : () => onIntent(const StartOrStopChangeSourceSearchIntent()),
            icon: Icon(state.searching ? Icons.stop_circle_outlined : Icons.refresh),
            tooltip: state.searching ? '停止搜索' : '重新搜索',
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  /// 根据初始化、致命错误和正常状态构建页面主体。
  Widget _buildBody(BuildContext context) {
    if (state.initializing) {
      return const AppLoadingView(message: '正在读取书籍和启用书源……');
    }
    /// 已完成初始化的旧书籍。
    final Book? oldBook = state.oldBook;
    if (oldBook == null) {
      return AppErrorView(message: state.errorMessage ?? '无法读取目标书籍');
    }
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            SpacingToken.medium,
            SpacingToken.medium,
            SpacingToken.medium,
            0,
          ),
          sliver: SliverList.list(
            children: <Widget>[
              _CurrentBookCard(book: oldBook),
              const SizedBox(height: SpacingToken.medium),
              _SearchControls(state: state, onIntent: onIntent),
              if (state.searching || state.progress.total > 0) ...<Widget>[
                const SizedBox(height: SpacingToken.medium),
                _SearchProgress(state: state),
              ],
              if (state.errorMessage case final String message) ...<Widget>[
                const SizedBox(height: SpacingToken.medium),
                _InlineErrorCard(message: message),
              ],
              if (state.failures.isNotEmpty) ...<Widget>[
                const SizedBox(height: SpacingToken.medium),
                _FailureSummary(failures: state.failures),
              ],
              if (state.selectedCandidate != null) ...<Widget>[
                const SizedBox(height: SpacingToken.medium),
                _CandidatePreview(state: state, onIntent: onIntent),
              ],
              const SizedBox(height: SpacingToken.medium),
              Text('候选来源', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: SpacingToken.small),
            ],
          ),
        ),
        if (state.candidates.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: AppEmptyView(
              message: state.searching
                  ? '正在从启用书源查找同名候选……'
                  : state.cancelled
                  ? '搜索已取消，可点击右上角继续'
                  : '没有找到符合条件的候选来源',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              SpacingToken.medium,
              0,
              SpacingToken.medium,
              SpacingToken.large,
            ),
            sliver: SliverList.builder(
              itemCount: state.candidates.length,
              itemBuilder: (BuildContext context, int index) {
                /// 当前稳定索引对应的候选书籍。
                final SearchBook candidate = state.candidates[index];
                /// 当前候选是否正在预览。
                final SearchBook? selectedCandidate = state.selectedCandidate;
                /// 以来源和详情 URL 判断选中状态，避免对象实例变化导致高亮丢失。
                final bool selected = selectedCandidate?.origin == candidate.origin &&
                    selectedCandidate?.bookUrl == candidate.bookUrl;
                return _CandidateTile(
                  candidate: candidate,
                  selected: selected,
                  onTap: () => onIntent(SelectChangeSourceCandidateIntent(candidate)),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// 展示当前书籍和不可逆换源提示。
final class _CurrentBookCard extends StatelessWidget {
  /// 创建当前书籍卡片。
  const _CurrentBookCard({required this.book});

  /// 正在被替换的旧书籍事实。
  final Book book;

  /// 构建书名、作者、来源和当前阅读位置。
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(book.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: SpacingToken.xSmall),
            Text('${book.author} · ${book.originName}'),
            const SizedBox(height: SpacingToken.small),
            Text(
              '当前进度：${book.durChapterTitle ?? '尚未阅读'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: SpacingToken.small),
            Text(
              '确认后会原子替换书籍主键和完整目录；返回或加载失败不会修改书架。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 展示作者过滤、书源范围和搜索开始/停止操作。
final class _SearchControls extends StatelessWidget {
  /// 创建换源搜索控制区。
  const _SearchControls({required this.state, required this.onIntent});

  /// 当前换源页面状态。
  final ChangeBookSourceUiState state;

  /// 页面 Intent 入口。
  final ValueChanged<ChangeBookSourceIntent> onIntent;

  /// 构建作者校验、来源范围和搜索按钮。
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('校验作者'),
              subtitle: const Text('开启后只保留作者包含当前作者的同名结果'),
              value: state.checkAuthor,
              onChanged: (bool enabled) {
                onIntent(ToggleChangeSourceAuthorCheckIntent(enabled));
              },
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: SpacingToken.small),
              title: Text(
                state.selectedSourceUrls.isEmpty
                    ? '搜索范围：全部启用书源'
                    : '搜索范围：${state.selectedSourceUrls.length} 个书源',
              ),
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    avatar: const Icon(Icons.select_all, size: 18),
                    label: const Text('全部启用书源'),
                    onPressed: () {
                      onIntent(const SelectAllChangeSourceScopesIntent());
                    },
                  ),
                ),
                const SizedBox(height: SpacingToken.small),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: SpacingToken.small,
                    runSpacing: SpacingToken.small,
                    children: state.sources.map((BookSource source) {
                      /// 空集合表示全部，因此所有 Chip 都显示为已选。
                      final bool selected = state.selectedSourceUrls.isEmpty ||
                          state.selectedSourceUrls.contains(source.bookSourceUrl);
                      return FilterChip(
                        selected: selected,
                        label: Text(source.bookSourceName),
                        onSelected: (bool value) {
                          onIntent(
                            ToggleChangeSourceScopeIntent(source.bookSourceUrl),
                          );
                        },
                      );
                    }).toList(growable: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SpacingToken.small),
            FilledButton.icon(
              onPressed: () {
                onIntent(const StartOrStopChangeSourceSearchIntent());
              },
              icon: Icon(state.searching ? Icons.stop : Icons.search),
              label: Text(state.searching ? '停止搜索' : '按当前范围重新搜索'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 展示有界多书源搜索进度和结果数量。
final class _SearchProgress extends StatelessWidget {
  /// 创建搜索进度区。
  const _SearchProgress({required this.state});

  /// 当前换源页面状态。
  final ChangeBookSourceUiState state;

  /// 构建线性进度和聚合计数。
  @override
  Widget build(BuildContext context) {
    /// 可计算时使用确定进度，否则显示不确定进度。
    final double? progressValue = state.progress.total <= 0
        ? null
        : (state.progress.completed / state.progress.total).clamp(0, 1).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        LinearProgressIndicator(value: state.searching ? progressValue : 1),
        const SizedBox(height: SpacingToken.small),
        Text(
          '已处理 ${state.progress.completed}/${state.progress.total}，'
          '失败 ${state.progress.failed}，候选 ${state.candidates.length}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 展示可恢复的页面级错误摘要。
final class _InlineErrorCard extends StatelessWidget {
  /// 创建行内错误卡片。
  const _InlineErrorCard({required this.message});

  /// 可安全展示的错误摘要。
  final String message;

  /// 构建带文本说明的错误容器。
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(message),
      ),
    );
  }
}

/// 汇总部分失败书源，不以失败阻断已有候选。
final class _FailureSummary extends StatelessWidget {
  /// 创建失败摘要区。
  const _FailureSummary({required this.failures});

  /// 当前单书源失败列表。
  final List<BookSearchSourceFailure> failures;

  /// 构建可展开的失败来源和安全摘要。
  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('${failures.length} 个书源搜索失败'),
      children: failures.map((BookSearchSourceFailure failure) {
        return ListTile(
          dense: true,
          title: Text(failure.sourceName),
          subtitle: Text('${failure.category}：${failure.message}'),
        );
      }).toList(growable: false),
    );
  }
}

/// 展示候选详情、目录统计、迁移选项和确认操作。
final class _CandidatePreview extends StatelessWidget {
  /// 创建候选预览区。
  const _CandidatePreview({required this.state, required this.onIntent});

  /// 当前换源页面状态。
  final ChangeBookSourceUiState state;

  /// 页面 Intent 入口。
  final ValueChanged<ChangeBookSourceIntent> onIntent;

  /// 构建加载、错误或可提交预览。
  @override
  Widget build(BuildContext context) {
    /// 用户选择的候选搜索结果。
    final SearchBook? candidate = state.selectedCandidate;
    if (candidate == null) {
      return const SizedBox.shrink();
    }
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '预览：${candidate.originName}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: state.applying
                      ? null
                      : () => onIntent(const DismissChangeSourcePreviewIntent()),
                  icon: const Icon(Icons.close),
                  tooltip: '关闭候选预览',
                ),
              ],
            ),
            if (state.loadingPreview) ...<Widget>[
              const LinearProgressIndicator(),
              const SizedBox(height: SpacingToken.small),
              const Text('正在加载候选详情和完整目录……'),
            ] else if (state.previewError case final String message) ...<Widget>[
              Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: SpacingToken.small),
              OutlinedButton(
                onPressed: () {
                  onIntent(SelectChangeSourceCandidateIntent(candidate));
                },
                child: const Text('重试候选'),
              ),
            ] else if (state.previewBook case final Book previewBook) ...<Widget>[
              Text('${previewBook.name} · ${previewBook.author}'),
              const SizedBox(height: SpacingToken.xSmall),
              Text(
                '目录 ${state.previewChapters.length} 章，最新：'
                '${previewBook.latestChapterTitle ?? '未知'}',
              ),
              const SizedBox(height: SpacingToken.medium),
              _MigrationOptions(
                options: state.options,
                enabled: !state.applying,
                onChanged: (ChangeSourceMigrationOptions options) {
                  onIntent(UpdateChangeSourceOptionsIntent(options));
                },
              ),
              const SizedBox(height: SpacingToken.medium),
              FilledButton.icon(
                onPressed: state.canApply
                    ? () => onIntent(const ConfirmChangeBookSourceIntent())
                    : null,
                icon: state.applying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.swap_horiz),
                label: Text(state.applying ? '正在换源……' : '确认整书换源'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 展示与 Android `ChangeSourceMigrationOptionsSheet` 对应的迁移选项。
final class _MigrationOptions extends StatelessWidget {
  /// 创建迁移选项区。
  const _MigrationOptions({
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  /// 当前完整迁移选项。
  final ChangeSourceMigrationOptions options;

  /// 是否允许用户修改选项。
  final bool enabled;

  /// 完整选项变化回调。
  final ValueChanged<ChangeSourceMigrationOptions> onChanged;

  /// 构建阅读位置、分组、封面、标签、备注和阅读设置选项。
  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      initiallyExpanded: true,
      title: const Text('迁移选项'),
      children: <Widget>[
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: options.migrateReadingProgress,
          onChanged: enabled
              ? (bool? value) {
                  onChanged(
                    options.copyWith(migrateReadingProgress: value ?? false),
                  );
                }
              : null,
          title: const Text('阅读进度'),
          subtitle: const Text('优先按章节标题映射，找不到时夹取旧章节索引'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: options.migrateGroup,
          onChanged: enabled
              ? (bool? value) {
                  onChanged(options.copyWith(migrateGroup: value ?? false));
                }
              : null,
          title: const Text('分组和排序'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: options.migrateCover,
          onChanged: enabled
              ? (bool? value) {
                  onChanged(options.copyWith(migrateCover: value ?? false));
                }
              : null,
          title: const Text('自定义封面'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: options.migrateCategory,
          onChanged: enabled
              ? (bool? value) {
                  onChanged(options.copyWith(migrateCategory: value ?? false));
                }
              : null,
          title: const Text('分类与标签'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: options.migrateRemark,
          onChanged: enabled
              ? (bool? value) {
                  onChanged(options.copyWith(migrateRemark: value ?? false));
                }
              : null,
          title: const Text('备注和自定义简介'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: options.migrateReadConfig,
          onChanged: enabled
              ? (bool? value) {
                  onChanged(options.copyWith(migrateReadConfig: value ?? false));
                }
              : null,
          title: const Text('单书阅读与显示设置'),
        ),
      ],
    );
  }
}

/// 展示一个换源候选的来源、章节和响应摘要。
final class _CandidateTile extends StatelessWidget {
  /// 创建稳定候选列表项。
  const _CandidateTile({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  /// 当前候选搜索结果。
  final SearchBook candidate;

  /// 当前候选是否正在预览。
  final bool selected;

  /// 选择候选回调。
  final VoidCallback onTap;

  /// 构建使用业务复合键的可点击候选卡片。
  @override
  Widget build(BuildContext context) {
    /// 候选辅助信息，优先展示最新章节，其次展示字数。
    final String detail = candidate.latestChapterTitle ??
        candidate.chapterWordCountText ??
        candidate.wordCount ??
        '详情和目录待加载';
    return Card(
      key: ValueKey<String>('${candidate.origin}\n${candidate.bookUrl}'),
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        onTap: onTap,
        leading: const Icon(Icons.source_outlined),
        title: Text(candidate.originName),
        subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
