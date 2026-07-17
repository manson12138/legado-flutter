import 'package:flutter/material.dart';

import '../../domain/model/bookmark.dart';
import '../../domain/model/replace_rule.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';

/// 当前章节搜索、书签编辑和替换统计等阅读辅助面板。
final class ReaderSearchSheetBody extends StatefulWidget {
  /// 创建当前章节搜索面板。
  const ReaderSearchSheetBody({
    required this.state,
    required this.onIntent,
    super.key,
  });

  /// 当前阅读器状态。
  final ReaderUiState state;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 创建搜索输入状态。
  @override
  State<ReaderSearchSheetBody> createState() => _ReaderSearchSheetBodyState();
}

/// 持有搜索输入框控制器，结果仍由 ViewModel 统一管理。
final class _ReaderSearchSheetBodyState extends State<ReaderSearchSheetBody> {
  /// 搜索词输入控制器。
  late final TextEditingController _controller;

  /// 初始化搜索词控制器。
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.searchState.query);
  }

  /// 外部状态变更时同步搜索框文本。
  @override
  void didUpdateWidget(covariant ReaderSearchSheetBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String nextQuery = widget.state.searchState.query;
    if (_controller.text != nextQuery) {
      _controller.value = TextEditingValue(
        text: nextQuery,
        selection: TextSelection.collapsed(offset: nextQuery.length),
      );
    }
  }

  /// 释放搜索词控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建搜索输入、结果计数和可点击匹配列表。
  @override
  Widget build(BuildContext context) {
    /// 当前搜索状态。
    final ReaderSearchState search = widget.state.searchState;
    /// 当前匹配总数。
    final int matchCount = search.matches.length;
    /// 当前结果序号。
    final int displayIndex = matchCount == 0 ? 0 : search.currentIndex + 1;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SpacingToken.medium,
              SpacingToken.medium,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '搜索正文',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: (String value) {
                      widget.onIntent(UpdateReaderSearchQueryIntent(value));
                    },
                    onSubmitted: (String value) {
                      widget.onIntent(UpdateReaderSearchQueryIntent(value));
                      widget.onIntent(const SubmitReaderSearchIntent());
                    },
                  ),
                ),
                const SizedBox(width: SpacingToken.small),
                FilledButton(
                  onPressed: search.searching
                      ? null
                      : () => widget.onIntent(const SubmitReaderSearchIntent()),
                  child: Text(search.searching ? '搜索中' : '搜索'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SpacingToken.medium,
              0,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: SegmentedButton<ReaderSearchScope>(
              segments: const <ButtonSegment<ReaderSearchScope>>[
                ButtonSegment<ReaderSearchScope>(
                  value: ReaderSearchScope.currentChapter,
                  icon: Icon(Icons.article_outlined),
                  label: Text('当前章'),
                ),
                ButtonSegment<ReaderSearchScope>(
                  value: ReaderSearchScope.wholeBook,
                  icon: Icon(Icons.menu_book_outlined),
                  label: Text('整本书'),
                ),
              ],
              selected: <ReaderSearchScope>{search.scope},
              onSelectionChanged: search.searching
                  ? null
                  : (Set<ReaderSearchScope> values) {
                      if (values.isEmpty) {
                        return;
                      }
                      widget.onIntent(UpdateReaderSearchScopeIntent(values.first));
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    search.searching
                        ? (search.scope == ReaderSearchScope.wholeBook ? '正在搜索整本书' : '正在搜索当前章')
                        : search.submitted
                            ? '结果 $displayIndex / $matchCount'
                            : '输入关键词后搜索正文',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  onPressed: matchCount == 0
                      ? null
                      : () => widget.onIntent(const NavigateReaderSearchResultIntent(-1)),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: '上一个结果',
                ),
                IconButton(
                  onPressed: matchCount == 0
                      ? null
                      : () => widget.onIntent(const NavigateReaderSearchResultIntent(1)),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  tooltip: '下一个结果',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: matchCount == 0
                ? Center(child: Text(search.submitted ? '没有匹配结果' : ''))
                : ListView.builder(
                    itemCount: matchCount,
                    itemBuilder: (BuildContext context, int index) {
                      /// 当前搜索结果。
                      final ReaderSearchMatch match = search.matches[index];
                      return ListTile(
                        selected: index == search.currentIndex,
                        leading: Text('${index + 1}'),
                        title: Text(
                          match.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          search.scope == ReaderSearchScope.wholeBook
                              ? '${match.chapterTitle} · 位置 ${match.start}'
                              : '位置 ${match.start}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => widget.onIntent(OpenReaderSearchResultIntent(index)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 书签备注编辑面板。
final class ReaderBookmarkEditSheetBody extends StatefulWidget {
  /// 创建书签备注编辑面板。
  const ReaderBookmarkEditSheetBody({
    required this.bookmark,
    required this.onIntent,
    super.key,
  });

  /// 当前编辑的书签。
  final Bookmark bookmark;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 创建备注编辑状态。
  @override
  State<ReaderBookmarkEditSheetBody> createState() => _ReaderBookmarkEditSheetBodyState();
}

/// 持有备注输入框草稿。
final class _ReaderBookmarkEditSheetBodyState extends State<ReaderBookmarkEditSheetBody> {
  /// 备注文本控制器。
  late final TextEditingController _controller;

  /// 初始化备注文本。
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.bookmark.content);
  }

  /// 释放备注文本控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建书签章节信息、原文摘要、备注输入和删除确认。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: SpacingToken.medium,
        top: SpacingToken.medium,
        right: SpacingToken.medium,
        bottom: MediaQuery.viewInsetsOf(context).bottom + SpacingToken.medium,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('编辑书签', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: SpacingToken.small),
          Text(
            widget.bookmark.chapterName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: SpacingToken.small),
          Text(
            widget.bookmark.bookText,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: SpacingToken.medium),
          TextField(
            controller: _controller,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '书签备注',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: SpacingToken.medium),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: () => _confirmDelete(context),
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: SpacingToken.small),
              FilledButton(
                onPressed: () {
                  widget.onIntent(
                    SaveReaderBookmarkNoteIntent(widget.bookmark, _controller.text),
                  );
                  Navigator.of(context).pop();
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 二次确认后删除当前书签。
  Future<void> _confirmDelete(BuildContext context) async {
    /// 用户确认结果。
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('删除书签'),
              content: const Text('确定删除这条书签吗？'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('删除'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed || !context.mounted) {
      return;
    }
    widget.onIntent(DeleteReaderBookmarkIntent(widget.bookmark));
    Navigator.of(context).pop();
  }
}

/// 替换规则当前章节统计面板。
final class ReaderReplaceInfoSheetBody extends StatelessWidget {
  /// 创建替换统计面板。
  const ReaderReplaceInfoSheetBody({
    required this.state,
    super.key,
  });

  /// 当前阅读器状态。
  final ReaderUiState state;

  /// 构建当前章节替换开关、生效数量和正文来源信息。
  @override
  Widget build(BuildContext context) {
    /// 当前章节替换命中数量。
    final int replaceCount = state.content?.effectiveReplaceRuleCount ?? 0;
    /// 当前章节是否来自正文缓存。
    final bool fromCache = state.content?.fromCache ?? false;
    /// 当前书可用的完整替换规则数量。
    final int ruleCount = state.replaceRules.length;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(SpacingToken.medium),
            child: Text('替换规则', style: Theme.of(context).textTheme.titleLarge),
          ),
          ListTile(
            leading: const Icon(Icons.rule),
            title: Text(state.config.useReplaceRules ? '已应用替换规则' : '未应用替换规则'),
            subtitle: Text('当前章节命中 $replaceCount 条；当前书可用 $ruleCount 条'),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(fromCache ? '正文来自缓存' : '正文来自本次加载'),
            subtitle: const Text('刷新章节可重新处理正文缓存和替换结果'),
          ),
          const Divider(height: 1),
          Expanded(
            child: ruleCount == 0
                ? const Center(child: Text('当前书没有可用正文替换规则'))
                : ListView.builder(
                    itemCount: ruleCount,
                    itemBuilder: (BuildContext context, int index) {
                      /// 当前替换规则。
                      final ReplaceRule rule = state.replaceRules[index];
                      /// 当前替换规则展示名称。
                      final String title = rule.name.isEmpty ? rule.pattern : rule.name;
                      /// 当前替换规则分组。
                      final String? group = rule.group;
                      /// 当前替换规则分组和模式摘要。
                      final String subtitle = <String>[
                        if (group != null && group.isNotEmpty) group,
                        rule.isRegex ? '正则' : '普通文本',
                        rule.scopeTitle ? '标题' : '正文',
                      ].join(' · ');
                      return ListTile(
                        leading: const Icon(Icons.find_replace),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 阅读器依赖型后续能力边界面板。
final class ReaderFutureFeaturesSheetBody extends StatelessWidget {
  /// 创建后续能力边界面板。
  const ReaderFutureFeaturesSheetBody({super.key});

  /// 构建不可误操作的后续能力清单。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(SpacingToken.medium),
            child: Text('后续能力', style: Theme.of(context).textTheme.titleLarge),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: _futureFeatures.map(_futureFeatureTile).toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建单个后续能力说明项。
  Widget _futureFeatureTile(_ReaderFutureFeature feature) {
    return ListTile(
      enabled: false,
      leading: Icon(feature.icon),
      title: Text(feature.title),
      subtitle: Text(feature.reason),
    );
  }
}

/// 阅读器后续能力说明项。
final class _ReaderFutureFeature {
  /// 创建后续能力说明项。
  const _ReaderFutureFeature({
    required this.icon,
    required this.title,
    required this.reason,
  });

  /// 能力图标。
  final IconData icon;

  /// 能力标题。
  final String title;

  /// 当前不能启用的原因。
  final String reason;
}

/// P4 依赖型能力清单，不把未完成能力伪装成可用按钮。
const List<_ReaderFutureFeature> _futureFeatures = <_ReaderFutureFeature>[
  _ReaderFutureFeature(
    icon: Icons.swap_calls,
    title: '单章换源',
    reason: '等待 M11 单章候选搜索、章节内容保存和回滚策略。',
  ),
  _ReaderFutureFeature(
    icon: Icons.download_outlined,
    title: '离线下载',
    reason: '等待下载队列、范围选择、失败重试和存储策略。',
  ),
  _ReaderFutureFeature(
    icon: Icons.record_voice_over_outlined,
    title: '朗读 / TTS',
    reason: '等待音频焦点、后台播放、媒体按钮和 TTS 配置迁移。',
  ),
  _ReaderFutureFeature(
    icon: Icons.play_circle_outline,
    title: '自动翻页',
    reason: '等待分页/滚动引擎真机验证后接入速度和退出保存。',
  ),
  _ReaderFutureFeature(
    icon: Icons.edit_note,
    title: '内容编辑',
    reason: '等待本地书和网络缓存章节的写入边界确认。',
  ),
  _ReaderFutureFeature(
    icon: Icons.auto_awesome,
    title: 'AI 总结 / 清理 / 改写',
    reason: '等待 AI 能力、隐私确认和替换确认链路。',
  ),
  _ReaderFutureFeature(
    icon: Icons.sync,
    title: '同步进度',
    reason: '等待 WebDAV/云同步能力和冲突处理迁移。',
  ),
];
