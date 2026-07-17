import 'package:flutter/material.dart';

import '../../domain/model/book_chapter.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';

/// 对齐 Android ReadBookMenuBar 的第一批 Flutter 阅读器沉浸菜单 Overlay。
final class ReaderMenuOverlay extends StatefulWidget {
  /// 创建阅读器顶部栏、章节进度和底部工具栏。
  const ReaderMenuOverlay({
    required this.state,
    required this.onIntent,
    super.key,
  });

  /// 当前阅读器可渲染状态。
  final ReaderUiState state;

  /// 阅读器用户操作统一入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 创建带本地拖动进度的菜单状态。
  @override
  State<ReaderMenuOverlay> createState() => _ReaderMenuOverlayState();
}

/// 持有章节滑杆拖动中的临时目标，松手后才提交给 ViewModel。
final class _ReaderMenuOverlayState extends State<ReaderMenuOverlay> {
  /// 当前拖动中的章节索引；为空时跟随 ViewModel 当前章节。
  double? _draftChapterIndex;

  /// 当外部章节变化后清除旧拖动草稿，避免显示过期目标。
  @override
  void didUpdateWidget(covariant ReaderMenuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.currentChapterIndex != widget.state.currentChapterIndex) {
      _draftChapterIndex = null;
    }
  }

  /// 构建覆盖在正文上方的顶栏、底栏和触摸穿透安全区域。
  @override
  Widget build(BuildContext context) {
    /// 菜单背景色。
    final Color backgroundColor = Color(widget.state.config.backgroundColorValue);
    /// 菜单前景色。
    final Color foregroundColor = Color(widget.state.config.textColorValue);
    /// 半透明菜单表面色。
    final Color surfaceColor = backgroundColor.withValues(alpha: 0.92);
    /// 阴影颜色。
    final Color shadowColor = Colors.black.withValues(alpha: 0.14);
    return IgnorePointer(
      ignoring: !widget.state.menuVisible,
      child: AnimatedOpacity(
        opacity: widget.state.menuVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                bottom: false,
                child: _ReaderTopBar(
                  state: widget.state,
                  foregroundColor: foregroundColor,
                  surfaceColor: surfaceColor,
                  shadowColor: shadowColor,
                  onIntent: widget.onIntent,
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                child: _ReaderBottomBar(
                  state: widget.state,
                  foregroundColor: foregroundColor,
                  surfaceColor: surfaceColor,
                  shadowColor: shadowColor,
                  draftChapterIndex: _draftChapterIndex,
                  onDraftChapterChanged: _updateDraftChapter,
                  onIntent: widget.onIntent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 更新滑杆草稿并刷新本地显示，不立即修改阅读进度。
  void _updateDraftChapter(double? value) {
    setState(() {
      _draftChapterIndex = value;
    });
  }
}

/// 阅读器顶部标题栏，对齐 Android MenuTitleBar 的 P0 子集。
final class _ReaderTopBar extends StatelessWidget {
  /// 创建顶部标题栏。
  const _ReaderTopBar({
    required this.state,
    required this.foregroundColor,
    required this.surfaceColor,
    required this.shadowColor,
    required this.onIntent,
  });

  /// 当前阅读器状态。
  final ReaderUiState state;

  /// 顶栏文字和图标颜色。
  final Color foregroundColor;

  /// 顶栏背景色。
  final Color surfaceColor;

  /// 顶栏阴影色。
  final Color shadowColor;

  /// 阅读器 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 构建返回、标题、刷新、换源和更多菜单。
  @override
  Widget build(BuildContext context) {
    /// 当前书名。
    final String bookName = state.book?.name ?? '阅读';
    /// 当前章节名。
    final String chapterName = state.currentChapter?.title ?? bookName;
    /// 当前是否为本地书。
    final bool isLocalBook = state.book?.origin == 'loc_book';
    /// 顶栏文字主题。
    final TextStyle? labelStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: foregroundColor.withValues(alpha: 0.72),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(
        SpacingToken.small,
        SpacingToken.small,
        SpacingToken.small,
        0,
      ),
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.small),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: shadowColor,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: IconTheme(
        data: IconThemeData(color: foregroundColor),
        child: Row(
          children: <Widget>[
            IconButton(
              onPressed: () => onIntent(const CloseReaderIntent()),
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回书架',
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    chapterName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: foregroundColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: state.loadState == ReaderLoadState.loading
                  ? null
                  : () => onIntent(const RetryReaderChapterIntent()),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新当前章',
            ),
            IconButton(
              onPressed: state.book == null || isLocalBook
                  ? null
                  : () => onIntent(const OpenReaderBookSourceChangeIntent()),
              icon: const Icon(Icons.swap_horiz),
              tooltip: '整书换源',
            ),
            PopupMenuButton<_ReaderTopMenuAction>(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              color: surfaceColor,
              onSelected: (_ReaderTopMenuAction action) {
                switch (action) {
                  case _ReaderTopMenuAction.addBookmark:
                    onIntent(const AddReaderBookmarkIntent());
                  case _ReaderTopMenuAction.settings:
                    onIntent(const ShowReaderSheetIntent(ReaderSettingsSheet()));
                  case _ReaderTopMenuAction.catalog:
                    onIntent(const ShowReaderSheetIntent(ReaderTocSheet()));
                  case _ReaderTopMenuAction.search:
                    onIntent(const ShowReaderSheetIntent(ReaderSearchSheet()));
                  case _ReaderTopMenuAction.replaceInfo:
                    onIntent(const ShowReaderSheetIntent(ReaderReplaceInfoSheet()));
                  case _ReaderTopMenuAction.refreshFollowing:
                    onIntent(
                      const RefreshReaderChaptersIntent(ReaderRefreshScope.followingChapters),
                    );
                  case _ReaderTopMenuAction.refreshAll:
                    onIntent(
                      const RefreshReaderChaptersIntent(ReaderRefreshScope.allChapters),
                    );
                  case _ReaderTopMenuAction.futureFeatures:
                    onIntent(const ShowReaderSheetIntent(ReaderFutureFeaturesSheet()));
                }
              },
              itemBuilder: (BuildContext context) {
                return <PopupMenuEntry<_ReaderTopMenuAction>>[
                  PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.addBookmark,
                    enabled: state.loadState == ReaderLoadState.ready,
                    child: const Text('添加书签'),
                  ),
                  const PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.catalog,
                    child: Text('目录'),
                  ),
                  PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.search,
                    enabled: state.loadState == ReaderLoadState.ready,
                    child: const Text('搜索正文'),
                  ),
                  PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.replaceInfo,
                    enabled: state.loadState == ReaderLoadState.ready,
                    child: const Text('替换统计'),
                  ),
                  PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.refreshFollowing,
                    enabled: state.loadState == ReaderLoadState.ready &&
                        !state.refreshingChapters &&
                        state.canGoNext,
                    child: const Text('刷新后续章节'),
                  ),
                  PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.refreshAll,
                    enabled: state.loadState == ReaderLoadState.ready &&
                        !state.refreshingChapters,
                    child: const Text('刷新全部章节'),
                  ),
                  const PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.futureFeatures,
                    child: Text('后续能力'),
                  ),
                  const PopupMenuItem<_ReaderTopMenuAction>(
                    value: _ReaderTopMenuAction.settings,
                    child: Text('显示设置'),
                  ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏更多菜单的 P0 动作。
enum _ReaderTopMenuAction {
  /// 添加当前阅读位置为书签。
  addBookmark,

  /// 打开显示设置。
  settings,

  /// 打开目录。
  catalog,

  /// 打开当前章节搜索。
  search,

  /// 打开当前章节替换统计。
  replaceInfo,

  /// 后台刷新后续章节正文缓存。
  refreshFollowing,

  /// 后台刷新全部章节正文缓存。
  refreshAll,

  /// 打开后续能力边界说明。
  futureFeatures,
}

/// 阅读器底部菜单，对齐 Android 工具栏和章节进度条的 P0 子集。
final class _ReaderBottomBar extends StatelessWidget {
  /// 创建底部工具栏。
  const _ReaderBottomBar({
    required this.state,
    required this.foregroundColor,
    required this.surfaceColor,
    required this.shadowColor,
    required this.draftChapterIndex,
    required this.onDraftChapterChanged,
    required this.onIntent,
  });

  /// 当前阅读器状态。
  final ReaderUiState state;

  /// 底栏文字和图标颜色。
  final Color foregroundColor;

  /// 底栏背景色。
  final Color surfaceColor;

  /// 底栏阴影色。
  final Color shadowColor;

  /// 当前滑杆拖动中的章节索引。
  final double? draftChapterIndex;

  /// 更新滑杆拖动目标。
  final ValueChanged<double?> onDraftChapterChanged;

  /// 阅读器 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 构建章节滑杆、状态文字和常用工具按钮。
  @override
  Widget build(BuildContext context) {
    /// 当前滑杆显示章节索引。
    final double sliderValue = draftChapterIndex ?? state.currentChapterIndex.toDouble();
    /// 滑杆目标索引。
    final int targetIndex = _nearestReadableIndex(sliderValue.round()) ?? state.currentChapterIndex;
    /// 当前显示的目标章节。
    final BookChapter? targetChapter = _chapterAt(targetIndex);
    /// 章节总数。
    final int chapterCount = state.chapters.length;
    /// 当前完整正文长度。
    final int textLength = state.content?.text.length ?? 0;
    /// 当前字符位置。
    final int characterOffset = state.anchor?.characterOffset ?? 0;
    /// 当前章节内阅读百分比。
    final int chapterPercent = textLength <= 1
        ? 0
        : ((characterOffset / (textLength - 1)).clamp(0, 1) * 100).round();
    return Container(
      margin: const EdgeInsets.all(SpacingToken.small),
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.small,
        SpacingToken.medium,
        SpacingToken.small,
      ),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: shadowColor,
            blurRadius: 20,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: IconTheme(
        data: IconThemeData(color: foregroundColor),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    targetChapter?.title ?? '目录未加载',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: foregroundColor.withValues(alpha: 0.76),
                    ),
                  ),
                ),
                const SizedBox(width: SpacingToken.small),
                Text(
                  '${state.currentChapterIndex + 1}/$chapterCount · $chapterPercent%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: foregroundColor.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: foregroundColor,
                inactiveTrackColor: foregroundColor.withValues(alpha: 0.24),
                thumbColor: foregroundColor,
                overlayColor: foregroundColor.withValues(alpha: 0.12),
              ),
              child: Slider(
                value: sliderValue.clamp(0, _sliderMax).toDouble(),
                min: 0,
                max: _sliderMax,
                onChanged: chapterCount <= 1
                    ? null
                    : (double value) => onDraftChapterChanged(value),
                onChangeEnd: chapterCount <= 1
                    ? null
                    : (double value) {
                        onDraftChapterChanged(null);
                        final int? readableIndex = _nearestReadableIndex(value.round());
                        if (readableIndex != null &&
                            readableIndex != state.currentChapterIndex) {
                          onIntent(OpenReaderChapterIntent(readableIndex));
                        }
                      },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                _ReaderToolButton(
                  icon: Icons.skip_previous,
                  label: '上一章',
                  enabled: state.canGoPrevious,
                  showLabel: state.config.showMenuToolLabels,
                  foregroundColor: foregroundColor,
                  onPressed: () => onIntent(const OpenPreviousChapterIntent()),
                ),
                _ReaderToolButton(
                  icon: Icons.format_list_numbered,
                  label: '目录',
                  enabled: state.chapters.isNotEmpty,
                  showLabel: state.config.showMenuToolLabels,
                  foregroundColor: foregroundColor,
                  onPressed: () => onIntent(const ShowReaderSheetIntent(ReaderTocSheet())),
                ),
                _ReaderToolButton(
                  icon: Icons.bookmarks_outlined,
                  label: '书签',
                  enabled: true,
                  showLabel: state.config.showMenuToolLabels,
                  foregroundColor: foregroundColor,
                  onPressed: () => onIntent(const ShowReaderSheetIntent(ReaderBookmarksSheet())),
                ),
                _ReaderToolButton(
                  icon: Icons.text_fields,
                  label: '设置',
                  enabled: true,
                  showLabel: state.config.showMenuToolLabels,
                  foregroundColor: foregroundColor,
                  onPressed: () => onIntent(const ShowReaderSheetIntent(ReaderSettingsSheet())),
                ),
                _ReaderToolButton(
                  icon: Icons.skip_next,
                  label: '下一章',
                  enabled: state.canGoNext,
                  showLabel: state.config.showMenuToolLabels,
                  foregroundColor: foregroundColor,
                  onPressed: () => onIntent(const OpenNextChapterIntent()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 滑杆最大值，目录为空时保持 0，避免 Slider 越界。
  double get _sliderMax {
    final int maxIndex = state.chapters.length - 1;
    return maxIndex <= 0 ? 0 : maxIndex.toDouble();
  }

  /// 安全读取指定索引章节。
  BookChapter? _chapterAt(int index) {
    if (index < 0 || index >= state.chapters.length) {
      return null;
    }
    return state.chapters[index];
  }

  /// 从目标索引查找最近的可阅读章节，优先向后，再向前回退。
  int? _nearestReadableIndex(int targetIndex) {
    if (state.chapters.isEmpty) {
      return null;
    }
    final int clampedIndex = targetIndex.clamp(0, state.chapters.length - 1).toInt();
    if (!state.chapters[clampedIndex].isVolume) {
      return clampedIndex;
    }
    for (int distance = 1; distance < state.chapters.length; distance += 1) {
      final int nextIndex = clampedIndex + distance;
      if (nextIndex < state.chapters.length && !state.chapters[nextIndex].isVolume) {
        return nextIndex;
      }
      final int previousIndex = clampedIndex - distance;
      if (previousIndex >= 0 && !state.chapters[previousIndex].isVolume) {
        return previousIndex;
      }
    }
    return null;
  }
}

/// 底部工具栏的图标和短标签按钮。
final class _ReaderToolButton extends StatelessWidget {
  /// 创建阅读工具按钮。
  const _ReaderToolButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.showLabel,
    required this.foregroundColor,
    required this.onPressed,
  });

  /// 按钮图标。
  final IconData icon;

  /// 按钮短标签。
  final String label;

  /// 当前按钮是否可用。
  final bool enabled;

  /// 是否显示按钮文字标签。
  final bool showLabel;

  /// 可用状态下的前景色。
  final Color foregroundColor;

  /// 点击后发送的阅读意图。
  final VoidCallback onPressed;

  /// 构建稳定宽度按钮，避免标签变化挤压相邻按钮。
  @override
  Widget build(BuildContext context) {
    /// 实际显示颜色。
    final Color color = enabled
        ? foregroundColor
        : foregroundColor.withValues(alpha: 0.32);
    return SizedBox(
      width: 56,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onPressed : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SpacingToken.xSmall),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: color, size: 22),
              if (showLabel) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
