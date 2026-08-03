import 'package:flutter/material.dart';

import '../../api/http/http_contract.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/manga_chapter.dart';
import '../../domain/model/manga_page.dart';
import '../../domain/model/manga_reader_config.dart';
import '../theme/app_tokens.dart';
import 'manga_page_view.dart';
import 'manga_reader_contract.dart';

/// 渲染连续条漫、工具栏、章节错误和目录面板的无业务页面。
final class MangaReaderScreen extends StatefulWidget {
  /// 创建条漫阅读页面。
  const MangaReaderScreen({
    required this.state,
    required this.resolveImage,
    required this.createImageCancellationToken,
    required this.onIntent,
    super.key,
  });

  /// 当前不可变漫画业务状态。
  final MangaReaderUiState state;

  /// 单张图片受控文件解析回调。
  final MangaPageResolver resolveImage;

  /// 图片 Cell 生命周期取消令牌工厂。
  final HttpCancellationTokenFactory createImageCancellationToken;

  /// 单一业务意图入口。
  final ValueChanged<MangaReaderIntent> onIntent;

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

/// 只管理条漫滚动控制器和跨章过度滚动锁的瞬时 UI 状态。
final class _MangaReaderScreenState extends State<MangaReaderScreen> {
  /// 当前条漫列表滚动控制器。
  final ScrollController _scrollController = ScrollController();

  /// 单页模式控制器；模式或章节变化时以领域图片索引重新创建。
  PageController? _pageController;

  /// 当前分页控制器所属模式。
  MangaReadingMode? _pageControllerMode;

  /// 当前分页控制器所属章节索引。
  int? _pageControllerChapterIndex;

  /// 离开条漫模式时按章节保留的精确滚动偏移。
  final Map<int, double> _webtoonOffsets = <int, double>{};

  /// 每个条漫偏移保存时对应的图片索引，防止单页翻页后错误复用旧偏移。
  final Map<int, int> _webtoonOffsetImageIndices = <int, int>{};

  /// 条漫深页恢复时绑定目标图片 Cell 的稳定锚点。
  final GlobalKey _webtoonRestoreKey = GlobalKey();

  /// 正在恢复的目标图片索引；非空期间忽略其他图片的中心位置回调。
  int? _pendingWebtoonImageIndex;

  /// 条漫恢复代次，拒绝模式或章节变化前安排的旧回调。
  int _webtoonRestoreGeneration = 0;

  /// 最近一次布局使用的窗口尺寸，用于旋转或分屏后恢复同一条漫图片。
  Size? _lastViewportSize;

  /// 一次过度滚动只允许触发一次跨章。
  bool _chapterTransitionLocked = false;

  /// 当前边界连续过度滚动的累计距离。
  double _boundaryOverscroll = 0;

  /// 当前路由内已经解析出的图片宽高比，避免 Cell 回收后重新退回未知高度。
  final Map<String, double> _webtoonAspectRatios = <String, double>{};

  /// 记录稳定图片宽高比，并限制路由级缓存规模。
  void _rememberWebtoonAspectRatio(String stableKey, double aspectRatio) {
    if (!aspectRatio.isFinite || aspectRatio <= 0) {
      return;
    }
    _webtoonAspectRatios.remove(stableKey);
    _webtoonAspectRatios[stableKey] = aspectRatio;
    while (_webtoonAspectRatios.length > 512) {
      final String? oldestKey = _webtoonAspectRatios.keys.isEmpty
          ? null
          : _webtoonAspectRatios.keys.first;
      if (oldestKey == null) {
        return;
      }
      _webtoonAspectRatios.remove(oldestKey);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    /// 当前安全区内可用窗口尺寸。
    final Size viewportSize = MediaQuery.sizeOf(context);
    final Size? previousSize = _lastViewportSize;
    _lastViewportSize = viewportSize;
    if (previousSize != null &&
        previousSize != viewportSize &&
        widget.state.readerConfig.readingMode.isWebtoon &&
        widget.state.currentChapter != null) {
      _scheduleWebtoonRestore();
    }
  }

  @override
  void didUpdateWidget(covariant MangaReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    /// 变更前使用的阅读方向。
    final MangaReadingMode oldMode = oldWidget.state.readerConfig.readingMode;
    /// 变更后使用的阅读方向。
    final MangaReadingMode newMode = widget.state.readerConfig.readingMode;
    if (oldMode.isWebtoon &&
        !newMode.isWebtoon &&
        _scrollController.hasClients) {
      _webtoonOffsets[oldWidget.state.currentChapterIndex] =
          _scrollController.offset;
      _webtoonOffsetImageIndices[oldWidget.state.currentChapterIndex] =
          oldWidget.state.currentImageIndex;
    }
    if (oldMode != newMode ||
        oldWidget.state.currentChapterIndex != widget.state.currentChapterIndex) {
      _pageController?.dispose();
      _pageController = null;
      _pageControllerMode = null;
      _pageControllerChapterIndex = null;
    }
    if (oldWidget.state.currentChapterIndex != widget.state.currentChapterIndex) {
      _chapterTransitionLocked = false;
      _boundaryOverscroll = 0;
      if (newMode.isWebtoon && widget.state.currentChapter != null) {
        _scheduleWebtoonRestore();
      }
    } else if (!oldMode.isWebtoon && newMode.isWebtoon) {
      _scheduleWebtoonRestore();
    } else if (newMode.isWebtoon &&
        oldWidget.state.currentChapter == null &&
        widget.state.currentChapter != null) {
      _scheduleWebtoonRestore();
    } else if (oldMode.isWebtoon && !newMode.isWebtoon) {
      _pendingWebtoonImageIndex = null;
      _webtoonRestoreGeneration += 1;
    }
  }

  /// 返回与当前模式、章节和稳定图片索引匹配的分页控制器。
  PageController _currentPageController(MangaReaderUiState state) {
    /// 当前已经存在的分页控制器。
    final PageController? current = _pageController;
    if (current != null &&
        _pageControllerMode == state.readerConfig.readingMode &&
        _pageControllerChapterIndex == state.currentChapterIndex) {
      return current;
    }
    /// 当前章节范围内的安全初始图片索引。
    final int initialPage = state.imageCount == 0
        ? 0
        : state.currentImageIndex.clamp(0, state.imageCount - 1).toInt();
    /// 以领域图片索引为锚点的新分页控制器。
    final PageController created = PageController(initialPage: initialPage);
    _pageController = created;
    _pageControllerMode = state.readerConfig.readingMode;
    _pageControllerChapterIndex = state.currentChapterIndex;
    return created;
  }

  /// 安排条漫按当前领域图片索引恢复，恢复完成前不允许首屏图片覆盖持久位置。
  void _scheduleWebtoonRestore() {
    final MangaChapter? chapter = widget.state.currentChapter;
    if (chapter == null || chapter.pages.isEmpty) {
      return;
    }
    /// 当前章节真实范围内的恢复目标图片。
    final int targetIndex = widget.state.currentImageIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    _pendingWebtoonImageIndex = targetIndex;
    final int generation = ++_webtoonRestoreGeneration;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _attemptWebtoonRestore(
        generation: generation,
        targetIndex: targetIndex,
        remainingAttempts: 6,
      );
    });
  }

  /// 先用列表估算范围跳到目标附近，再以目标 Cell 的真实位置居中完成恢复。
  void _attemptWebtoonRestore({
    required int generation,
    required int targetIndex,
    required int remainingAttempts,
  }) {
    if (!mounted ||
        generation != _webtoonRestoreGeneration ||
        !_scrollController.hasClients) {
      return;
    }
    /// 目标图片已被惰性列表构建时可直接按真实布局居中。
    final BuildContext? targetContext = _webtoonRestoreKey.currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.5,
        duration: Duration.zero,
      ).whenComplete(() {
        if (mounted && generation == _webtoonRestoreGeneration) {
          _pendingWebtoonImageIndex = null;
        }
      });
      return;
    }
    /// 之前离开同一章节条漫时保存的精确滚动位置。
    final double? savedOffset = _webtoonOffsets[widget.state.currentChapterIndex];
    /// 仅当图片索引未在单页模式变化时才能安全复用旧条漫偏移。
    final bool canUseSavedOffset =
        _webtoonOffsetImageIndices[widget.state.currentChapterIndex] ==
            targetIndex;
    /// 尚未构建目标 Cell 时按列表估算总范围和图片比例跳到目标附近。
    final double proportionalOffset = widget.state.imageCount <= 1
        ? 0
        : _scrollController.position.maxScrollExtent *
            targetIndex /
            (widget.state.imageCount - 1);
    /// 收敛后的本轮跳转位置。
    final double targetOffset = (canUseSavedOffset ? savedOffset : null) ??
        proportionalOffset;
    /// 收敛到当前列表真实滚动范围的安全偏移。
    final double safeTargetOffset = targetOffset
        .clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        )
        .toDouble();
    _scrollController.jumpTo(safeTargetOffset);
    if (remainingAttempts <= 0) {
      _pendingWebtoonImageIndex = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _attemptWebtoonRestore(
        generation: generation,
        targetIndex: targetIndex,
        remainingAttempts: remainingAttempts - 1,
      );
    });
  }

  /// 处理列表边界继续拖动，达到阈值时切换上一章或下一章。
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      _chapterTransitionLocked = false;
      _boundaryOverscroll = 0;
      return false;
    }
    if (notification is! OverscrollNotification || _chapterTransitionLocked) {
      return false;
    }
    if (_boundaryOverscroll != 0 &&
        _boundaryOverscroll.sign != notification.overscroll.sign) {
      _boundaryOverscroll = 0;
    }
    _boundaryOverscroll += notification.overscroll;
    if (_boundaryOverscroll > 48 && widget.state.canGoNextChapter) {
      _chapterTransitionLocked = true;
      widget.onIntent(const NextMangaChapterIntent());
    } else if (_boundaryOverscroll < -48 &&
        widget.state.canGoPreviousChapter) {
      _chapterTransitionLocked = true;
      widget.onIntent(const PreviousMangaChapterIntent());
    }
    return false;
  }

  /// 打开完整目录底部面板，卷标题不可点击。
  Future<void> _showToc() async {
    /// 用户从目录选择的章节索引。
    final int? selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.8,
            child: ListView.builder(
              itemCount: widget.state.chapters.length,
              itemBuilder: (BuildContext context, int index) {
                /// 当前目录章节。
                final BookChapter chapter = widget.state.chapters[index];
                return ListTile(
                  enabled: !chapter.isVolume,
                  selected: index == widget.state.currentChapterIndex,
                  leading: chapter.isVolume
                      ? const Icon(Icons.folder_outlined)
                      : Text('${index + 1}'),
                  title: Text(
                    chapter.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: chapter.isVolume
                      ? null
                      : () => Navigator.of(context).pop(index),
                );
              },
            ),
          ),
        );
      },
    );
    if (selected != null) {
      widget.onIntent(JumpToMangaChapterIntent(selected));
    }
  }

  /// 打开阅读方向设置面板；选择后保持当前章节和图片索引不变。
  Future<void> _showReaderSettings() async {
    /// 用户选中的目标阅读方向。
    final MangaReadingMode? selected = await showModalBottomSheet<MangaReadingMode>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ListTile(
                leading: Icon(Icons.chrome_reader_mode_outlined),
                title: Text('漫画阅读方向'),
                subtitle: Text('缩放图片时会暂时锁定翻页手势'),
              ),
              // 为四种首版阅读方向各提供一个明确选择项。
              for (final MangaReadingMode mode in MangaReadingMode.values)
                RadioListTile<MangaReadingMode>(
                  value: mode,
                  groupValue: widget.state.readerConfig.readingMode,
                  title: Text(mode.label),
                  secondary: Icon(_modeIcon(mode)),
                  onChanged: (MangaReadingMode? value) =>
                      Navigator.of(context).pop(value),
                ),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      widget.onIntent(ChangeMangaReadingModeIntent(selected));
    }
  }

  /// 返回阅读方向设置项对应图标。
  IconData _modeIcon(MangaReadingMode mode) {
    return switch (mode) {
      MangaReadingMode.leftToRight => Icons.arrow_forward,
      MangaReadingMode.rightToLeft => Icons.arrow_back,
      MangaReadingMode.verticalPage => Icons.arrow_downward,
      MangaReadingMode.webtoon => Icons.view_stream_outlined,
    };
  }

  /// 构建章节级失败的显式恢复动作，不把登录或付费错误转成自动重试循环。
  Widget _chapterRecoveryActions() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: SpacingToken.small,
      runSpacing: SpacingToken.small,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => widget.onIntent(const RetryMangaChapterIntent()),
          icon: const Icon(Icons.replay_outlined),
          label: const Text('重试'),
        ),
        OutlinedButton.icon(
          onPressed: () => widget.onIntent(
            const RetryMangaChapterIntent(forceRefresh: true),
          ),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新章节'),
        ),
        OutlinedButton.icon(
          onPressed: () => widget.onIntent(const OpenMangaSourceLoginIntent()),
          icon: const Icon(Icons.login_outlined),
          label: const Text('书源登录'),
        ),
        OutlinedButton.icon(
          onPressed: () => widget.onIntent(const OpenMangaChangeSourceIntent()),
          icon: const Icon(Icons.swap_horiz_outlined),
          label: const Text('整书换源'),
        ),
      ],
    );
  }

  /// 构建当前章节主体。
  Widget _body() {
    /// 当前不可变页面状态。
    final MangaReaderUiState state = widget.state;
    if (state.loadState == MangaReaderLoadState.initializing ||
        state.loadState == MangaReaderLoadState.loadingChapter) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.loadState == MangaReaderLoadState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.large),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: SpacingToken.medium),
              Text(
                state.errorMessage ?? '漫画章节加载失败',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SpacingToken.medium),
              _chapterRecoveryActions(),
            ],
          ),
        ),
      );
    }
    /// 当前完成解析的漫画章节。
    final MangaChapter? chapter = state.currentChapter;
    if (chapter == null || chapter.pages.isEmpty) {
      /// 无图片章节的状态说明。
      final String message = switch (chapter?.state) {
        MangaChapterContentState.volume => '当前目录项是卷标题',
        MangaChapterContentState.emptyContent => '章节正文为空，请刷新或更换书源',
        MangaChapterContentState.noImages => '章节正文中没有可读取图片',
        _ => '当前章节没有图片',
      };
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.large),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.image_not_supported_outlined, size: 48),
              const SizedBox(height: SpacingToken.medium),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: SpacingToken.medium),
              _chapterRecoveryActions(),
            ],
          ),
        ),
      );
    }
    if (!state.readerConfig.readingMode.isWebtoon) {
      return _singlePageBody(state, chapter);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ListView.builder(
        controller: _scrollController,
        cacheExtent: MediaQuery.sizeOf(context).height * 1.5,
        physics: state.isZoomed
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: chapter.pages.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == chapter.pages.length) {
            return _ChapterBoundaryFooter(
              canGoNext: state.canGoNextChapter,
              onNext: () => widget.onIntent(const NextMangaChapterIntent()),
            );
          }
          /// 当前惰性构建的漫画图片页。
          final MangaPage page = chapter.pages[index];
          /// 深页恢复目标使用 GlobalKey，其他图片继续使用稳定页面 Key。
          final Key pageKey = index == _pendingWebtoonImageIndex
              ? _webtoonRestoreKey
              : ValueKey<String>(page.stableKey);
          return Padding(
            key: pageKey,
            padding: EdgeInsets.symmetric(
              horizontal: state.readerConfig.webtoonSidePadding,
            ),
            child: MangaPageView(
              page: page,
              scrollController: _scrollController,
              resolveImage: widget.resolveImage,
              createCancellationToken: widget.createImageCancellationToken,
              onVisible: (int imageIndex) {
                if (_pendingWebtoonImageIndex == null) {
                  widget.onIntent(MangaVisibleImageChangedIntent(imageIndex));
                }
              },
              onFirstFrame: (int imageIndex) => widget.onIntent(
                MangaImageDisplayedIntent(imageIndex),
              ),
              onTap: () => widget.onIntent(const ToggleMangaMenuIntent()),
              isCurrentPage: index == state.currentImageIndex,
              enableZoom: true,
              placeholderAspectRatio: _webtoonAspectRatios[page.stableKey],
              onAspectRatioResolved: (double aspectRatio) =>
                  _rememberWebtoonAspectRatio(page.stableKey, aspectRatio),
              onZoomChanged: (bool isZoomed) =>
                  widget.onIntent(MangaZoomChangedIntent(isZoomed)),
            ),
          );
        },
      ),
    );
  }

  /// 构建横向或纵向单页阅读器。
  Widget _singlePageBody(MangaReaderUiState state, MangaChapter chapter) {
    /// 当前单页阅读方向。
    final MangaReadingMode mode = state.readerConfig.readingMode;
    return PageView.builder(
      key: ValueKey<String>('${state.currentChapterIndex}-${mode.name}'),
      controller: _currentPageController(state),
      scrollDirection: mode.isVerticalPage ? Axis.vertical : Axis.horizontal,
      reverse: mode.isRightToLeft,
      allowImplicitScrolling: false,
      physics: state.isZoomed
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: chapter.pages.length,
      onPageChanged: (int imageIndex) => widget.onIntent(
        MangaVisibleImageChangedIntent(imageIndex),
      ),
      itemBuilder: (BuildContext context, int index) {
        /// 当前惰性构建的分页漫画图片。
        final MangaPage page = chapter.pages[index];
        return MangaPageView(
          key: ValueKey<String>('single-${page.stableKey}'),
          page: page,
          scrollController: _scrollController,
          resolveImage: widget.resolveImage,
          createCancellationToken: widget.createImageCancellationToken,
          onVisible: (int imageIndex) => widget.onIntent(
            MangaVisibleImageChangedIntent(imageIndex),
          ),
          onFirstFrame: (int imageIndex) => widget.onIntent(
            MangaImageDisplayedIntent(imageIndex),
          ),
          onTap: () => widget.onIntent(const ToggleMangaMenuIntent()),
          trackScrollVisibility: false,
          isCurrentPage: index == state.currentImageIndex,
          enableZoom: true,
          evictDecodedImageOnDispose: true,
          imageAlignment: mode.isVerticalPage
              ? Alignment.topCenter
              : Alignment.center,
          onZoomChanged: (bool isZoomed) =>
              widget.onIntent(MangaZoomChangedIntent(isZoomed)),
        );
      },
    );
  }

  /// 构建覆盖在漫画上方的沉浸式标题栏，不参与正文尺寸计算。
  Widget _topMenu(
    MangaReaderUiState state, {
    required String title,
    required String subtitle,
  }) {
    return Align(
      alignment: Alignment.topCenter,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 3,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: kToolbarHeight,
            child: AppBar(
              primary: false,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: '刷新章节',
                  onPressed: () => widget.onIntent(
                    const RetryMangaChapterIntent(forceRefresh: true),
                  ),
                  icon: const Icon(Icons.refresh),
                ),
                if (!state.isInBookshelf)
                  IconButton(
                    tooltip: '加入书架',
                    onPressed: state.addingToBookshelf
                        ? null
                        : () => widget.onIntent(
                              const AddMangaToBookshelfIntent(),
                            ),
                    icon: state.addingToBookshelf
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bookmark_add_outlined),
                  ),
                IconButton(
                  tooltip: '目录',
                  onPressed: _showToc,
                  icon: const Icon(Icons.format_list_numbered),
                ),
                IconButton(
                  tooltip: '阅读设置',
                  onPressed: _showReaderSettings,
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建覆盖在漫画下方的沉浸式章节栏，背景延伸到屏幕底部安全区。
  Widget _bottomMenu(MangaReaderUiState state) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 8,
        child: SafeArea(
          top: false,
          child: BottomAppBar(
            elevation: 0,
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: '上一章',
                  onPressed: state.canGoPreviousChapter
                      ? () => widget.onIntent(const PreviousMangaChapterIntent())
                      : null,
                  icon: const Icon(Icons.skip_previous),
                ),
                Expanded(
                  child: Text(
                    '${state.currentChapterIndex + 1}/${state.chapters.length} · '
                    '${state.imageCount == 0 ? 0 : state.currentImageIndex + 1}/${state.imageCount} · '
                    '${state.readerConfig.readingMode.label}',
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  tooltip: '下一章',
                  onPressed: state.canGoNextChapter
                      ? () => widget.onIntent(const NextMangaChapterIntent())
                      : null,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 为沉浸式菜单提供淡入和上下滑入效果，隐藏状态不拦截漫画手势。
  Widget _animatedMenu({required bool visible, required Widget child, required Offset hiddenOffset}) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : hiddenOffset,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    /// 当前不可变页面状态。
    final MangaReaderUiState state = widget.state;
    /// 当前书名占位。
    final String title = state.book?.name.trim().isNotEmpty == true
        ? state.book?.name ?? '漫画阅读'
        : '漫画阅读';
    /// 当前章节标题占位。
    final String subtitle = state.currentChapter?.chapter.title ??
        (state.currentChapterIndex >= 0 &&
                state.currentChapterIndex < state.chapters.length
            ? state.chapters[state.currentChapterIndex].title
            : '正在准备章节');
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IconTheme(
              data: const IconThemeData(color: Colors.white70),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white70),
                child: _body(),
              ),
            ),
          ),
          Positioned.fill(
            child: _animatedMenu(
              visible: state.menuVisible,
              hiddenOffset: const Offset(0, -1),
              child: _topMenu(state, title: title, subtitle: subtitle),
            ),
          ),
          Positioned.fill(
            child: _animatedMenu(
              visible: state.menuVisible,
              hiddenOffset: const Offset(0, 1),
              child: _bottomMenu(state),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController?.dispose();
    super.dispose();
  }
}

/// 条漫章节末尾的下一章入口。
final class _ChapterBoundaryFooter extends StatelessWidget {
  /// 创建章节边界提示。
  const _ChapterBoundaryFooter({required this.canGoNext, required this.onNext});

  /// 是否存在下一可阅读章节。
  final bool canGoNext;

  /// 切换下一章回调。
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpacingToken.large,
        vertical: SpacingToken.xLarge,
      ),
      child: Center(
        child: canGoNext
            ? FilledButton.tonalIcon(
                onPressed: onNext,
                icon: const Icon(Icons.expand_more),
                label: const Text('下一章'),
              )
            : const Text('已到全书末尾', style: TextStyle(color: Colors.white70)),
      ),
    );
  }
}

/// 避免 Screen 依赖具体 HTTP 实现的取消令牌工厂类型。
typedef HttpCancellationTokenFactory = HttpCancellationToken Function();
