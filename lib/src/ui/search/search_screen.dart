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
            child: _SearchField(state: state, onIntent: onIntent),
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

/// 搜索输入框，自带受控 [TextEditingController]，用于支持带动画的一键清空按钮。
final class _SearchField extends StatefulWidget {
  /// 创建搜索输入框。
  const _SearchField({required this.state, required this.onIntent});
  /// 当前状态。
  final SearchUiState state;
  /// Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

/// 持有输入控制器，双向同步外部状态与用户输入。
final class _SearchFieldState extends State<_SearchField> {
  /// 输入框文本控制器，驱动清空按钮的显隐动画。
  late final TextEditingController _controller;

  /// 用当前状态关键字初始化控制器并监听用户输入。
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.keyword)..addListener(_handleControllerChanged);
  }

  /// 用户输入变化时同步回 ViewModel；忽略程序化赋值触发的重复事件。
  void _handleControllerChanged() {
    if (_controller.text != widget.state.keyword) {
      widget.onIntent(ChangeSearchKeywordIntent(_controller.text));
    }
  }

  /// 已提交关键字被外部改变（历史点击、清空搜索）时，把输入框文本同步过去。
  @override
  void didUpdateWidget(covariant _SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.committedKeyword != widget.state.committedKeyword &&
        _controller.text != widget.state.keyword) {
      _controller.value = TextEditingValue(
        text: widget.state.keyword,
        selection: TextSelection.collapsed(offset: widget.state.keyword.length),
      );
    }
  }

  /// 释放控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建输入框、动画清空按钮和搜索/停止按钮。
  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      onFieldSubmitted: (String value) => widget.onIntent(SubmitSearchIntent(keyword: value)),
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: InputDecoration(
        labelText: '书名或作者',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.search),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (BuildContext context, TextEditingValue value, Widget? child) {
                return _ClearSearchButton(visible: value.text.isNotEmpty, onPressed: _controller.clear);
              },
            ),
            widget.state.searching
                ? IconButton(
                    onPressed: () => widget.onIntent(const CancelSearchIntent()),
                    icon: const Icon(Icons.stop_circle_outlined),
                    tooltip: '停止搜索',
                  )
                : IconButton(
                    onPressed: () => widget.onIntent(const SubmitSearchIntent()),
                    icon: const Icon(Icons.arrow_forward),
                    tooltip: '开始搜索',
                  ),
          ],
        ),
      ),
    );
  }
}

/// 有输入内容时以动画淡入淡出并展开/收起的一键清空按钮。
final class _ClearSearchButton extends StatelessWidget {
  /// 创建清空按钮。
  const _ClearSearchButton({required this.visible, required this.onPressed});
  /// 是否应显示。
  final bool visible;
  /// 点击回调。
  final VoidCallback onPressed;

  /// 用 [AnimatedSize] 配合 [AnimatedOpacity] 让按钮显隐时平滑收展。
  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeInOut,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          child: visible
              ? IconButton(
                  onPressed: onPressed,
                  icon: const Icon(Icons.close),
                  tooltip: '清空',
                )
              : const SizedBox.shrink(),
        ),
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
    return _SearchResultPages(state: state, onIntent: onIntent);
  }
}

/// 搜索结果的展示分类；同一去重结果只会进入其中一个页面。
enum _SearchResultCategory {
  /// 关键字命中书名。
  title,

  /// 关键字命中作者，且未命中书名。
  author,

  /// 关键字未命中书名和作者的补充结果。
  other,
}

/// 单个搜索结果 PageView 页面的不可变展示数据。
final class _SearchResultPageData {
  /// 创建分类页面数据。
  const _SearchResultPageData({required this.category, required this.label, required this.groups});

  /// 页面分类。
  final _SearchResultCategory category;

  /// 页面切换栏展示文案。
  final String label;

  /// 当前页面内的稳定结果组。
  final List<BookSearchResultGroup> groups;
}

/// 将已提交关键字对应的结果按书名、作者和其他分类。
List<_SearchResultPageData> _buildSearchResultPages(SearchUiState state) {
  /// 用于匹配的已提交关键字，避免编辑中的输入改变当前结果分类。
  final String keyword = state.committedKeyword.trim().toLowerCase();
  /// 书名匹配结果。
  final List<BookSearchResultGroup> titleResults = <BookSearchResultGroup>[];
  /// 作者匹配结果。
  final List<BookSearchResultGroup> authorResults = <BookSearchResultGroup>[];
  /// 非书名、作者匹配的补充结果。
  final List<BookSearchResultGroup> otherResults = <BookSearchResultGroup>[];
  for (final BookSearchResultGroup group in state.results) {
    /// 当前结果组的书名匹配情况。
    final bool titleMatches = group.primary.name.trim().toLowerCase().contains(keyword);
    /// 当前结果组的作者匹配情况。
    final bool authorMatches = group.primary.author.trim().toLowerCase().contains(keyword);
    if (titleMatches) {
      titleResults.add(group);
    } else if (authorMatches) {
      authorResults.add(group);
    } else {
      otherResults.add(group);
    }
  }
  return <_SearchResultPageData>[
    _SearchResultPageData(category: _SearchResultCategory.title, label: '书名', groups: titleResults),
    _SearchResultPageData(category: _SearchResultCategory.author, label: '作者', groups: authorResults),
    if (otherResults.isNotEmpty)
      _SearchResultPageData(category: _SearchResultCategory.other, label: '其他', groups: otherResults),
  ];
}

/// 用 PageView 分开展示书名、作者和可选其他搜索结果。
final class _SearchResultPages extends StatefulWidget {
  /// 创建结果分类页面。
  const _SearchResultPages({required this.state, required this.onIntent});

  /// 搜索页不可变状态。
  final SearchUiState state;

  /// 页面统一 Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  @override
  State<_SearchResultPages> createState() => _SearchResultPagesState();
}

/// 管理 PageController，确保“其他”页出现或消失时页码仍然有效。
final class _SearchResultPagesState extends State<_SearchResultPages> {
  /// 当前分类页面控制器。
  late PageController _pageController;

  /// 当前页面数量，用于在页面结构改变时安全重建控制器。
  late int _pageCount;

  /// 当前可见页下标，驱动轻量切换栏。
  int _selectedPage = 0;

  @override
  void initState() {
    super.initState();
    /// 首次渲染时的页面数量。
    _pageCount = _buildSearchResultPages(widget.state).length;
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(covariant _SearchResultPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    /// 更新后的分类页面数量。
    final int nextPageCount = _buildSearchResultPages(widget.state).length;
    if (nextPageCount != _pageCount) {
      /// 结构变更前仍可恢复的页码。
      final int nextSelectedPage = _selectedPage.clamp(0, nextPageCount - 1).toInt();
      _pageController.dispose();
      _pageController = PageController(initialPage: nextSelectedPage);
      _pageCount = nextPageCount;
      _selectedPage = nextSelectedPage;
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 切换到用户选中的结果分类页面。
  void _selectPage(int index) {
    if (index == _selectedPage) {
      return;
    }
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    /// 当前状态计算出的分类页面。
    final List<_SearchResultPageData> pages = _buildSearchResultPages(widget.state);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
          child: _SearchResultPageSelector(
            pages: pages,
            selectedPage: _selectedPage,
            onSelected: _selectPage,
          ),
        ),
        const SizedBox(height: SpacingToken.xSmall),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: pages.length,
            onPageChanged: (int index) => setState(() => _selectedPage = index),
            itemBuilder: (BuildContext context, int index) {
              /// 当前分类页面数据。
              final _SearchResultPageData page = pages[index];
              return _SearchResultList(
                key: PageStorageKey<String>('search-result-${page.category.name}'),
                groups: page.groups,
                emptyText: '没有匹配${page.label}的结果',
                onIntent: widget.onIntent,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 搜索结果分类的轻量页面切换栏。
final class _SearchResultPageSelector extends StatelessWidget {
  /// 创建分类切换栏。
  const _SearchResultPageSelector({required this.pages, required this.selectedPage, required this.onSelected});

  /// 可展示页面。
  final List<_SearchResultPageData> pages;

  /// 当前页码。
  final int selectedPage;

  /// 选择页面回调。
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      children: List<Widget>.generate(pages.length, (int index) {
        /// 当前页数据。
        final _SearchResultPageData page = pages[index];
        /// 当前页是否被选择。
        final bool selected = index == selectedPage;
        return Expanded(
          child: Semantics(
            button: true,
            selected: selected,
            label: '${page.label}，${page.groups.length} 条结果',
            child: InkWell(
              borderRadius: BorderRadius.circular(RadiusToken.medium),
              onTap: () => onSelected(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: SpacingToken.small),
                decoration: BoxDecoration(
                  color: selected ? colors.secondaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(RadiusToken.medium),
                ),
                child: Text(
                  '${page.label} ${page.groups.length}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// 分类页面内复用的虚拟化结果列表。
final class _SearchResultList extends StatelessWidget {
  /// 创建分类结果列表。
  const _SearchResultList({required this.groups, required this.emptyText, required this.onIntent, super.key});

  /// 当前分类的结果组。
  final List<BookSearchResultGroup> groups;

  /// 当前分类没有结果时的提示。
  final String emptyText;

  /// 页面统一 Intent 入口。
  final ValueChanged<SearchIntent> onIntent;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return Center(child: Text(emptyText));
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 宽屏下把结果约束在舒适阅读宽度内的水平留白。
        final double horizontalPadding = constraints.maxWidth > LayoutToken.contentMaxWidth
            ? (constraints.maxWidth - LayoutToken.contentMaxWidth) / 2
            : SpacingToken.medium;
        return ListView.separated(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: SpacingToken.small),
          itemCount: groups.length,
          separatorBuilder: (BuildContext context, int index) => const Divider(),
          itemBuilder: (BuildContext context, int index) {
            /// 当前稳定结果组。
            final BookSearchResultGroup group = groups[index];
            return Material(
              key: ValueKey<String>(group.key),
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onIntent(OpenSearchResultIntent(group, group.primary)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: SpacingToken.small),
                  child: Row(
                    children: <Widget>[
                      SizedBox(width: 35, height: 51, child: _SearchResultCover(group: group)),
                      const SizedBox(width: SpacingToken.mediumSmall),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(group.primary.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                            Text(group.primary.author.isEmpty ? '未知作者' : group.primary.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: SpacingToken.xSmall),
                            Text('${group.primary.originName} · ${group.books.length} 个来源', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
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
