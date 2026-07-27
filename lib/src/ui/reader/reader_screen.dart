import 'package:flutter/material.dart';

import '../../domain/model/book_content_process.dart';
import '../../domain/model/reader_content.dart';
import '../../help/logging/app_logger.dart';
import '../theme/app_tokens.dart';
import 'reader_contract.dart';
import 'reader_content_image.dart';
import 'reader_edge_swipe_exit.dart';
import 'reader_menu_overlay.dart';
import 'reader_page_layout.dart';
import 'reader_selection_region.dart';
import 'reader_simulation_page_turn.dart';
import 'reader_tap_region.dart';

/// 只消费 ReaderUiState、布局控制器并发送 Intent 的无状态小说阅读页面。
final class ReaderScreen extends StatelessWidget {
  /// 创建阅读器纯 UI。
  const ReaderScreen({
    required this.state,
    required this.onIntent,
    required this.scrollController,
    required this.logger,
    super.key,
  });

  /// ViewModel 提供的完整不可变状态。
  final ReaderUiState state;

  /// 用户操作统一入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 路由层持有的瞬时滚动控制器，不进入业务 UiState。
  final ScrollController scrollController;

  /// 【FLUTTER_READER_SIMULATION_LOG】仿真翻页临时诊断日志使用的统一应用日志器。
  final AppLogger logger;

  /// 构建可隐藏菜单、惰性正文和章节控制栏。
  @override
  Widget build(BuildContext context) {
    /// 阅读背景色。
    final Color backgroundColor = Color(state.config.backgroundColorValue);
    /// 非全屏模式下系统状态栏和导航栏常驻显示，正文需要避让；全屏沉浸模式下系统栏被
    /// 隐藏，不需要额外让出空间。
    final bool avoidsSystemBars = !state.config.fullScreen;
    return Scaffold(
      backgroundColor: backgroundColor,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ReaderEdgeSwipeExitRegion(
              enabled: state.config.edgeSwipeToCloseEnabled &&
                  !state.menuVisible &&
                  state.activeSheet == null,
              onExit: () => onIntent(const CloseReaderIntent()),
              child: ColoredBox(
                color: backgroundColor,
                child: SafeArea(
                  left: avoidsSystemBars,
                  top: avoidsSystemBars,
                  right: avoidsSystemBars,
                  bottom: avoidsSystemBars,
                  child: _buildBody(context),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ReaderMenuOverlay(
              state: state,
              onIntent: onIntent,
            ),
          ),
          if (state.menuVisible && !state.isInBookshelf)
            Positioned(
              right: SpacingToken.large,
              bottom: 176,
              child: SafeArea(
                top: false,
                left: false,
                child: FloatingActionButton.small(
                  heroTag: 'reader-add-to-bookshelf',
                  tooltip: '加入书架',
                  onPressed: state.addingToBookshelf
                      ? null
                      : () => onIntent(
                            const AddReaderBookToBookshelfIntent(),
                          ),
                  child: state.addingToBookshelf
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bookmark_add_outlined),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 根据加载状态构建初始化、错误或可持续显示的正文区域。
  Widget _buildBody(BuildContext context) {
    if (state.loadState == ReaderLoadState.error) {
      return _ReaderErrorBody(
        message: state.errorMessage ?? '章节正文加载失败',
        onRetry: () => onIntent(const RetryReaderChapterIntent()),
      );
    }
    /// 当前可继续展示的正文；相邻章节加载时保留旧章，避免列表刷新和空白转圈。
    final ReaderChapterContent? content = state.content;
    if (content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    /// 当前章节的分页正文组件。
    final Widget pagedContent = ReaderPagedContent(
      key: ValueKey<String>(content.chapterUrl),
      state: state,
      onIntent: onIntent,
      logger: logger,
    );
    /// 当前是否启用由阅读器接管的左右覆盖或仿真翻页。
    final bool usesCustomHorizontalTurn =
        state.config.readingMode == ReaderReadingMode.horizontalPaging &&
        (state.config.pageTurnStyle == ReaderPageTurnStyle.cover ||
            state.config.pageTurnStyle ==
                ReaderPageTurnStyle.simulation);
    /// 当前阅读模式对应的正文组件。
    final Widget readableContent;
    if (state.config.readingMode == ReaderReadingMode.continuous) {
      readableContent = _ReaderContentList(
        state: state,
        scrollController: scrollController,
        onIntent: onIntent,
      );
    } else if (usesCustomHorizontalTurn) {
      readableContent = _ReaderChapterPageTurnSwitch(
        chapterUrl: content.chapterUrl,
        direction: state.chapterTransitionDirection,
        animateTransition: state.animateChapterTransition,
        pageTurnStyle: state.config.pageTurnStyle,
        paperColor: Color(state.config.backgroundColorValue),
        child: pagedContent,
      );
    } else {
      readableContent = pagedContent;
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            ignoring: state.loadState == ReaderLoadState.loading,
            child: readableContent,
          ),
        ),
        if (state.loadState == ReaderLoadState.loading)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

/// 在相邻章节之间保持旧页，并按当前覆盖或仿真策略进入新章节。
final class _ReaderChapterPageTurnSwitch extends StatefulWidget {
  /// 创建跨章节自定义翻页切换容器。
  const _ReaderChapterPageTurnSwitch({
    required this.chapterUrl,
    required this.direction,
    required this.animateTransition,
    required this.pageTurnStyle,
    required this.paperColor,
    required this.child,
  });

  /// 当前已加载章节的稳定 URL。
  final String chapterUrl;

  /// 章节切换方向；正数移走旧章进入下一章，负数从左侧覆盖进入上一章。
  final int direction;

  /// 新章节就绪后是否播放跨章动画；边界手势已经展示目标页时关闭。
  final bool animateTransition;

  /// 当前左右分页使用的覆盖或仿真动画策略。
  final ReaderPageTurnStyle pageTurnStyle;

  /// 当前阅读纸张颜色，用于仿真页背着色。
  final Color paperColor;

  /// 当前章节已经完成分页的正文组件。
  final Widget child;

  /// 创建章节覆盖切换的瞬时动画状态。
  @override
  State<_ReaderChapterPageTurnSwitch> createState() =>
      _ReaderChapterPageTurnSwitchState();
}

/// 保存跨章节动画期间的新旧正文组件，不把动画进度写入业务状态。
final class _ReaderChapterPageTurnSwitchState
    extends State<_ReaderChapterPageTurnSwitch>
    with SingleTickerProviderStateMixin {
  /// 驱动新章节覆盖旧章节的动画控制器。
  late final AnimationController _controller;

  /// 当前稳定显示的章节组件。
  late Widget _currentChild;

  /// 动画期间保持静止的上一章节组件。
  Widget? _previousChild;

  /// 当前稳定显示章节的 URL。
  late String _currentChapterUrl;

  /// 当前覆盖进入方向。
  int _direction = 1;

  /// 初始化章节组件和覆盖动画。
  @override
  void initState() {
    super.initState();
    _currentChild = widget.child;
    _currentChapterUrl = widget.chapterUrl;
    _controller = AnimationController(
      vsync: this,
      duration: DurationToken.medium,
      value: 1,
    );
  }

  /// 接收新章节时保留旧组件，当前章内部状态变化时只更新现有组件。
  @override
  void didUpdateWidget(covariant _ReaderChapterPageTurnSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chapterUrl == _currentChapterUrl) {
      _currentChild = widget.child;
      return;
    }
    _previousChild = _currentChild;
    _currentChild = widget.child;
    _currentChapterUrl = widget.chapterUrl;
    if (!widget.animateTransition) {
      _previousChild = null;
      _controller.value = 1;
      return;
    }
    _direction = widget.direction < 0 ? -1 : 1;
    _controller.value = 0;
    /// 当前跨章节覆盖动画任务。
    final Future<void> animation = _controller.forward();
    animation.whenComplete(() {
      if (!mounted) {
        return;
      }
      setState(() {
        _previousChild = null;
      });
    });
  }

  /// 释放章节覆盖动画控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建旧页固定、新页横向覆盖的章节切换画面。
  @override
  Widget build(BuildContext context) {
    /// 本帧需要保持在底层的旧章节组件。
    final Widget? previousChild = _previousChild;
    if (previousChild == null) {
      return _currentChild;
    }
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          if (widget.pageTurnStyle == ReaderPageTurnStyle.simulation) {
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                /// 当前跨章节仿真页面宽度。
                final double width = constraints.maxWidth;
                /// 当前跨章节仿真页面高度。
                final double height = constraints.maxHeight;
                /// 当前跨章节程序化动画进度。
                final double progress = _controller.value;
                /// 下一章从右下卷到左侧屏外，上一章从左侧展开到右下页角。
                final Offset touch = _direction > 0
                    ? Offset(
                        width * 0.9 +
                            (-width - width * 0.9) * progress,
                        height * 0.9 + height * 0.1 * progress,
                      )
                    : Offset(width * progress, height);
                return ExcludeSemantics(
                  child: IgnorePointer(
                    child: ReaderSimulationPageTurnFrame(
                      currentPage: previousChild,
                      targetPage: _currentChild,
                      direction: _direction,
                      progress: progress,
                      touch: touch,
                      corner: Offset(width, height),
                      paperColor: widget.paperColor,
                    ),
                  ),
                );
              },
            );
          }
          /// 当前可用页面宽度。
          final double width = MediaQuery.sizeOf(context).width;
          if (_direction > 0) {
            /// 进入下一章时新章固定在底层，旧章末页向左移走。
            final double oldPageOffset = -_controller.value * width;
            return Stack(
              children: <Widget>[
                Positioned.fill(child: _currentChild),
                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(oldPageOffset, 0),
                    child: _buildMovingPage(previousChild),
                  ),
                ),
              ],
            );
          }
          /// 进入上一章时旧章固定在底层，上一章末页从左侧覆盖回来。
          final double newPageOffset = -(1 - _controller.value) * width;
          return Stack(
            children: <Widget>[
              Positioned.fill(child: previousChild),
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(newPageOffset, 0),
                  child: _buildMovingPage(_currentChild),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 为跨章节移动纸张添加与单页覆盖一致的右边缘阴影。
  Widget _buildMovingPage(Widget page) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(4, 0),
          ),
        ],
      ),
      child: page,
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
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null &&
            state.menuVisible) {
          onIntent(const HideReaderMenuIntent());
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
        if (notification is ScrollEndNotification &&
            notification.metrics.extentAfter <= 1 &&
            state.canGoNext) {
          onIntent(const OpenNextChapterIntent());
        }
        if (notification is OverscrollNotification &&
            notification.metrics.extentBefore <= 1 &&
            notification.overscroll < -18 &&
            state.canGoPrevious) {
          onIntent(const OpenPreviousChapterIntent());
        }
        return false;
      },
      child: ReaderTapRegion(
        onTapUp: (Offset position) {
          _handleTap(position.dx, MediaQuery.sizeOf(context).width);
        },
        child: ListView.builder(
        controller: scrollController,
        /// 显示页眉时页眉只需贴近安全区留出固定小间距，不再叠加用户配置的阅读边距。
        padding: EdgeInsets.fromLTRB(
          state.config.horizontalPadding,
          state.config.showHeaderFooter
              ? SpacingToken.small
              : state.config.verticalPadding,
          state.config.horizontalPadding,
          state.config.verticalPadding,
        ),
        itemCount: content.blocks.length + 2,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (state.config.showHeaderFooter)
                  _ReaderInlineHeader(state: state),
                if (state.config.titleMode != ReaderTitleMode.hidden)
                  Padding(
                    padding: EdgeInsets.only(
                      top: state.config.titleTopSpacing,
                      bottom: state.config.titleBottomSpacing,
                    ),
                    child: Text(
                      content.title,
                      textAlign: state.config.titleMode == ReaderTitleMode.center
                          ? TextAlign.center
                          : TextAlign.start,
                      style: TextStyle(
                        color: Color(state.config.textColorValue),
                        fontSize: state.config.fontSize +
                            state.config.titleFontSizeOffset,
                        fontWeight: _fontWeight(state.config.titleFontWeightValue),
                        fontStyle: state.config.textItalic
                            ? FontStyle.italic
                            : FontStyle.normal,
                        letterSpacing: state.config.letterSpacing,
                        decoration: state.config.textUnderline
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        shadows: _textShadows(state),
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
            );
          }
          if (index == content.blocks.length + 1) {
            return _ChapterEndActions(
              state: state,
              onIntent: onIntent,
              showFooter: state.config.showHeaderFooter,
            );
          }
          /// 当前稳定正文块。
          final block = content.blocks[index - 1];
          if (block.kind == ReaderContentBlockKind.image) {
            return Padding(
              key: ValueKey<String>(block.id),
              padding: EdgeInsets.only(bottom: state.config.paragraphSpacing),
              child: ReaderContentImageView(
                imageUrl: block.resourceUrl,
                altText: block.altText,
                referer: block.resourceReferer,
                onSave: () => onIntent(
                  ShareReaderContentImageIntent(block.resourceUrl),
                ),
              ),
            );
          }
          return Padding(
            key: ValueKey<String>(block.id),
            padding: EdgeInsets.only(bottom: state.config.paragraphSpacing),
            child: _buildSelectableTextBlock(content, block),
          );
        },
      ),
      ),
    );
  }

  /// 按用户配置把连续阅读正文点击区域映射为阅读动作。
  void _handleTap(double x, double width) {
    /// 当前左侧点击区域宽度。
    final double leftWidth = width * state.config.leftTapWidthRatio;
    /// 当前右侧点击区域起点。
    final double rightStart = width * (1 - state.config.rightTapWidthRatio);
    if (x < leftWidth) {
      _performTapAction(state.config.leftTapAction);
      return;
    }
    if (x > rightStart) {
      _performTapAction(state.config.rightTapAction);
      return;
    }
    _performTapAction(state.config.centerTapAction);
  }

  /// 执行连续阅读点击和按键共享的阅读动作；正文长按固定交给原生选区。
  void _performTapAction(ReaderTapAction action) {
    switch (action) {
      case ReaderTapAction.none:
        return;
      case ReaderTapAction.previousPage:
        _openPreviousPageOrChapter();
        return;
      case ReaderTapAction.nextPage:
        _openNextPageOrChapter();
        return;
      case ReaderTapAction.toggleMenu:
        onIntent(const ToggleReaderMenuIntent());
        return;
      case ReaderTapAction.addBookmark:
        onIntent(const AddReaderBookmarkIntent());
        return;
    }
  }

  /// 构建与章节字符位置一一对应的可选正文块，并叠加用户高亮和下划线。
  Widget _buildSelectableTextBlock(
    ReaderChapterContent content,
    ReaderContentBlock block,
  ) {
    /// 当前正文块的基础排版样式。
    final TextStyle baseStyle = TextStyle(
      color: Color(state.config.textColorValue),
      fontSize: state.config.fontSize,
      fontWeight: _fontWeight(state.config.fontWeightValue),
      fontStyle:
          state.config.textItalic ? FontStyle.italic : FontStyle.normal,
      letterSpacing: state.config.letterSpacing,
      decoration: state.config.textUnderline
          ? TextDecoration.underline
          : TextDecoration.none,
      shadows: _textShadows(state),
      height: state.config.lineHeight,
    );
    /// 只用于显示、不进入章节字符锚点的全角首行缩进。
    final String indent =
        List<String>.filled(state.config.paragraphIndent, '　').join();
    /// 当前正文块按真实换行拆分的段落。
    final List<String> paragraphs = block.text.split('\n');
    /// 最终交给 RichText 的显示片段。
    final List<InlineSpan> spans = <InlineSpan>[];
    /// 当前段落在正文块中的字符起点。
    int localOffset = 0;
    for (int index = 0; index < paragraphs.length; index += 1) {
      /// 当前保持原文字符位置的段落。
      final String paragraph = paragraphs[index];
      if (index > 0) {
        spans.add(TextSpan(text: '\n', style: baseStyle));
      }
      if (indent.isNotEmpty) {
        spans.add(TextSpan(text: indent, style: baseStyle));
      }
      spans.addAll(
        buildReaderAnnotationSpans(
          chapterText: content.text,
          text: paragraph,
          startOffset: block.startOffset + localOffset,
          baseStyle: baseStyle,
          processes: state.contentProcesses,
        ),
      );
      localOffset += paragraph.length + 1;
    }
    return ReaderSelectionRegion(
      chapterText: content.text,
      scopeStart: block.startOffset,
      scopeEnd: block.endOffset,
      preferredOffset:
          state.anchor?.characterOffset ?? block.startOffset,
      selectionEpoch: state.restoreRequestId,
      onAction: (
        ReaderTextSelection selection,
        ReaderSelectionAction action,
      ) {
        onIntent(ApplyReaderSelectionIntent(selection, action));
      },
      child: Text.rich(
        TextSpan(children: spans),
        textAlign:
            state.config.textFullJustify ? TextAlign.justify : TextAlign.start,
      ),
    );
  }

  /// 连续模式优先向上滚动一个视口，到达顶部后进入上一章。
  void _openPreviousPageOrChapter() {
    if (scrollController.hasClients) {
      /// 当前滚动位置。
      final ScrollPosition position = scrollController.position;
      /// 向上翻一屏后的目标像素。
      final double target = (position.pixels - position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (target < position.pixels) {
        scrollController.animateTo(
          target,
          duration: DurationToken.medium,
          curve: AnimationToken.standard,
        );
        return;
      }
    }
    if (state.canGoPrevious) {
      onIntent(const OpenPreviousChapterIntent());
    }
  }

  /// 连续模式优先向下滚动一个视口，到达底部后进入下一章。
  void _openNextPageOrChapter() {
    if (scrollController.hasClients) {
      /// 当前滚动位置。
      final ScrollPosition position = scrollController.position;
      /// 向下翻一屏后的目标像素。
      final double target = (position.pixels + position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (target > position.pixels) {
        scrollController.animateTo(
          target,
          duration: DurationToken.medium,
          curve: AnimationToken.standard,
        );
        return;
      }
    }
    if (state.canGoNext) {
      onIntent(const OpenNextChapterIntent());
    }
  }

  /// 返回两个整数的较大值，避免仅为一个表达式引入业务无关依赖。
  int mathMax(int left, int right) => left > right ? left : right;

  /// 将跨平台保存的字重数值映射为 Flutter 字体权重。
  FontWeight _fontWeight(int value) {
    return switch (value) {
      300 => FontWeight.w300,
      500 => FontWeight.w500,
      600 => FontWeight.w600,
      700 => FontWeight.w700,
      _ => FontWeight.w400,
    };
  }

  /// 根据阅读配置生成轻量正文阴影。
  List<Shadow>? _textShadows(ReaderUiState state) {
    if (!state.config.textShadow) {
      return null;
    }
    return <Shadow>[
      Shadow(
        color: Color(state.config.textColorValue).withValues(alpha: 0.28),
        blurRadius: 1.5,
        offset: const Offset(0.6, 0.8),
      ),
    ];
  }
}

/// 连续滚动正文顶部的轻量页眉信息。
final class _ReaderInlineHeader extends StatelessWidget {
  /// 创建连续滚动页眉。
  const _ReaderInlineHeader({required this.state});

  /// 当前阅读状态。
  final ReaderUiState state;

  /// 构建书名、章节和章节进度信息。
  @override
  Widget build(BuildContext context) {
    /// 当前正文长度。
    final int textLength = state.content?.text.length ?? 0;
    /// 当前稳定字符位置。
    final int characterOffset = state.anchor?.characterOffset ?? 0;
    /// 当前章节百分比。
    final int percent = textLength <= 1
        ? 0
        : ((characterOffset / (textLength - 1)).clamp(0, 1) * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: SpacingToken.medium),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${state.book?.name ?? '阅读'} · ${state.currentChapter?.title ?? ''} · $percent%',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Color(state.config.textColorValue).withValues(alpha: 0.58),
                fontSize: 11,
              ),
            ),
          ),
          ReaderSystemInfoText(
            config: state.config,
            batteryLevel: state.batteryLevel,
            textColor: Color(state.config.textColorValue).withValues(alpha: 0.58),
            fontSize: 11,
          ),
        ],
      ),
    );
  }
}

/// 展示章末状态和连续阅读入口。
final class _ChapterEndActions extends StatelessWidget {
  /// 创建章末操作区。
  const _ChapterEndActions({
    required this.state,
    required this.onIntent,
    required this.showFooter,
  });

  /// 当前阅读状态。
  final ReaderUiState state;

  /// 阅读 Intent 入口。
  final ValueChanged<ReaderIntent> onIntent;

  /// 是否显示章节来源和替换统计页脚。
  final bool showFooter;

  /// 构建缓存来源、替换统计和连续阅读边界提示。
  @override
  Widget build(BuildContext context) {
    /// 当前正文结果。
    final content = state.content;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SpacingToken.large),
      child: Column(
        children: <Widget>[
          Divider(color: Color(state.config.textColorValue).withValues(alpha: 0.25)),
          if (showFooter)
            Text(
              content?.fromCache == true ? '本章来自正文缓存' : '本章来自书源请求',
              style: TextStyle(color: Color(state.config.textColorValue).withValues(alpha: 0.65)),
            ),
          if (showFooter && (content?.effectiveReplaceRuleCount ?? 0) > 0)
            Text(
              '已应用 ${content?.effectiveReplaceRuleCount ?? 0} 条替换规则',
              style: TextStyle(color: Color(state.config.textColorValue).withValues(alpha: 0.65)),
            ),
          const SizedBox(height: SpacingToken.medium),
          Text(
            state.canGoNext ? '继续上滑，自动进入下一章' : '已到最后一章',
            style: TextStyle(
              color: Color(state.config.textColorValue).withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }
}
