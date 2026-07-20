import 'package:flutter/material.dart';

import '../../domain/model/book_chapter.dart';
import '../../domain/model/search_book.dart';
import '../theme/app_tokens.dart';
import 'change_chapter_source_contract.dart';

/// 单章换源面板的纯 UI；只消费 [ChangeChapterSourceUiState] 并发送 Intent。
///
/// 在候选搜索列表和候选目录列表之间由 [ChangeChapterSourceUiState.showToc] 切换，
/// 与 Android `ChangeChapterSourceSheet` 的两段式布局保持一致。
final class ChangeChapterSourceSheetBody extends StatelessWidget {
  /// 创建单章换源面板 UI。
  const ChangeChapterSourceSheetBody({
    required this.state,
    required this.onIntent,
    super.key,
  });

  /// ViewModel 提供的完整不可变状态。
  final ChangeChapterSourceUiState state;

  /// 面板所有用户操作的统一 Intent 入口。
  final ValueChanged<ChangeChapterSourceIntent> onIntent;

  /// 按当前视图构建候选列表或候选目录。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: state.showToc ? _buildTocView(context) : _buildSearchView(context),
    );
  }

  /// 构建候选搜索列表视图。
  Widget _buildSearchView(BuildContext context) {
    return Column(
      children: <Widget>[
        ListTile(
          title: const Text('单章换源'),
          subtitle: Text('当前章节：${state.chapterTitle}'),
          trailing: IconButton(
            onPressed: () => onIntent(const StartOrStopChangeChapterSourceSearchIntent()),
            icon: Icon(state.searching ? Icons.stop_circle_outlined : Icons.refresh),
            tooltip: state.searching ? '停止搜索' : '重新搜索',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
          child: Row(
            children: <Widget>[
              FilterChip(
                selected: state.checkAuthor,
                label: const Text('校验作者'),
                onSelected: (bool value) =>
                    onIntent(ToggleChangeChapterSourceAuthorCheckIntent(value)),
              ),
              const SizedBox(width: SpacingToken.small),
              Expanded(
                child: Text(
                  state.searching
                      ? '搜索中：${state.progress.completed}/${state.progress.total} · 已找到 ${state.candidates.length} 个候选'
                      : state.cancelled
                      ? '搜索已取消，可点击右上角继续'
                      : '共 ${state.candidates.length} 个候选',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (state.searching || state.progress.total > 0)
          LinearProgressIndicator(
            value: state.progress.total == 0
                ? null
                : state.progress.completed / state.progress.total,
          ),
        if (state.errorMessage case final String message)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SpacingToken.medium,
              vertical: SpacingToken.small,
            ),
            child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const Divider(height: 1),
        Expanded(
          child: state.candidates.isEmpty
              ? Center(
                  child: Text(
                    state.searching ? '正在从启用书源查找同名候选……' : '没有找到符合条件的候选来源',
                  ),
                )
              : ListView.builder(
                  itemCount: state.candidates.length,
                  itemBuilder: (BuildContext context, int index) {
                    /// 当前候选来源。
                    final SearchBook candidate = state.candidates[index];
                    return ListTile(
                      title: Text(candidate.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${candidate.originName} · ${candidate.author}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onIntent(SelectChangeChapterSourceCandidateIntent(candidate)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 构建候选完整目录视图。
  Widget _buildTocView(BuildContext context) {
    /// 当前候选来源。
    final SearchBook? candidate = state.selectedCandidate;
    return Column(
      children: <Widget>[
        ListTile(
          leading: IconButton(
            onPressed: () => onIntent(const BackFromChangeChapterSourceTocIntent()),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回候选列表',
          ),
          title: Text(candidate?.originName ?? '候选目录', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('点击目标章节以替换正文：${state.chapterTitle}'),
        ),
        if (state.loadingToc) const LinearProgressIndicator(),
        if (state.fetchingContent) const LinearProgressIndicator(),
        if (state.tocError case final String message)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SpacingToken.medium,
              vertical: SpacingToken.small,
            ),
            child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const Divider(height: 1),
        Expanded(
          child: state.loadingToc
              ? const Center(child: Text('正在加载候选目录……'))
              : state.tocChapters.isEmpty
              ? Center(child: Text(state.tocError ?? '候选目录为空'))
              : ListView.builder(
                  itemCount: state.tocChapters.length,
                  itemBuilder: (BuildContext context, int index) {
                    /// 当前目录章节。
                    final BookChapter chapter = state.tocChapters[index];
                    /// 是否为模糊匹配预选的章节。
                    final bool preselected = index == state.preselectedTocIndex;
                    return ListTile(
                      selected: preselected,
                      enabled: state.canSelectChapter && !chapter.isVolume,
                      leading: chapter.isVolume
                          ? const Icon(Icons.folder_outlined)
                          : Text('${index + 1}'),
                      title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: preselected ? const Text('与当前章节最接近的匹配') : null,
                      onTap: chapter.isVolume
                          ? null
                          : () => onIntent(SelectChangeChapterSourceTocChapterIntent(chapter)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
