import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../help/logging/app_logger.dart';
import '../theme/app_tokens.dart';

/// 表示本次阅读器边缘手势从左侧或右侧物理屏幕边缘开始。
enum ReaderExitEdge {
  /// 从左侧边缘向右滑动。
  left,

  /// 从右侧边缘向左滑动。
  right,
}

/// 只在双侧物理屏幕边缘起手时识别向内滑动退出，并保持正文手势继续参与竞技场。
final class ReaderEdgeSwipeExitRegion extends StatefulWidget {
  /// 创建双侧边缘滑动退出区域。
  const ReaderEdgeSwipeExitRegion({
    required this.leftEnabled,
    required this.rightEnabled,
    required this.onExit,
    required this.logger,
    required this.child,
    super.key,
  });

  /// 是否允许左侧物理边缘向右滑动退出。
  final bool leftEnabled;

  /// 是否允许右侧物理边缘向左滑动退出。
  final bool rightEnabled;

  /// 手势达到提交阈值后调用的统一阅读器退出入口。
  final VoidCallback onExit;

  /// 【FLUTTER_REWRITE_DEBUG_LOG】记录边缘命中、竞技场胜负和退出提交阶段的统一日志接口。
  final AppLogger logger;

  /// 需要保留原翻页、滚动、短按和文字选择行为的阅读正文。
  final Widget child;

  /// 创建只保存单次边缘手势瞬时状态的 State。
  @override
  State<ReaderEdgeSwipeExitRegion> createState() =>
      _ReaderEdgeSwipeExitRegionState();
}

/// 管理边缘方向、有效位移和轻量退出反馈，不保存业务进度或路由状态。
final class _ReaderEdgeSwipeExitRegionState
    extends State<ReaderEdgeSwipeExitRegion> {
  /// 边缘识别器优先于普通横向翻页取得控制所使用的受控触摸松弛距离。
  static const double _edgeTouchSlop = 10;

  /// 快速甩动提交退出所需的最小正确方向速度；与正文翻页的 500 logical px/s
  /// 手感保持一致，避免同一次边缘甩动达到翻页标准却达不到退出标准。
  static const double _commitVelocity = 500;

  /// 当前边缘起手方向；没有候选手势时为空。
  ReaderExitEdge? _edge;

  /// 当前手势相对起点的累计水平位移。
  double _horizontalDistance = 0;

  /// 当前反馈相对退出阈值的受控进度。
  double _feedbackProgress = 0;

  /// 当前反馈图标在屏幕纵向的起手位置。
  double _feedbackY = 0;

  /// 当前是否显示边缘退出提示。
  bool _feedbackVisible = false;

  /// 当前路由生命周期内是否已经提交退出，防止同一组件重复发送关闭 Intent。
  bool _exitCommitted = false;

  /// 【FLUTTER_REWRITE_DEBUG_LOG】最近一次已经输出的识别器布局配置，避免每次拖动重建都重复写日志。
  String? _lastLoggedConfiguration;

  /// 【FLUTTER_REWRITE_DEBUG_LOG】本次边缘拖动是否已经输出首个更新日志，避免跟手阶段逐帧刷日志。
  bool _dragUpdateLogged = false;

  /// 记录边缘区域首次挂载时的开关状态。
  @override
  void initState() {
    super.initState();
    // FLUTTER_REWRITE_DEBUG_LOG：确认阅读器正文外层确实创建了边缘返回区域。
    widget.logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker regionInit '
          'leftEnabled=${widget.leftEnabled} '
          'rightEnabled=${widget.rightEnabled}',
    );
  }

  /// 设置关闭时立即清理手势反馈，不让旧候选在重新开启后继续。
  @override
  void didUpdateWidget(ReaderEdgeSwipeExitRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.leftEnabled != widget.leftEnabled ||
        oldWidget.rightEnabled != widget.rightEnabled) {
      // FLUTTER_REWRITE_DEBUG_LOG：菜单、Sheet 或用户设置变化都通过该状态判断识别器是否注册。
      widget.logger.info(
        tag: readerEdgeSwipeExitLogTag,
        message: '$readerEdgeSwipeExitDebugLogMarker enabledChanged '
            'left=${oldWidget.leftEnabled}->${widget.leftEnabled} '
            'right=${oldWidget.rightEnabled}->${widget.rightEnabled} '
            'exitCommitted=$_exitCommitted',
      );
    }
    /// 当前左右两侧是否都已经关闭，关闭后正文获得完整的原始手势范围。
    final bool bothEdgesDisabled =
        !widget.leftEnabled && !widget.rightEnabled;
    if (bothEdgesDisabled) {
      _horizontalDistance = 0;
      _feedbackProgress = 0;
      _feedbackVisible = false;
      _dragUpdateLogged = false;
    }
  }

  /// 记录边缘区域释放，确认日志中途停止是路由退出而不是识别器静默失效。
  @override
  void dispose() {
    // FLUTTER_REWRITE_DEBUG_LOG：释放日志只描述瞬时手势状态，不记录正文或书籍信息。
    widget.logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker regionDispose '
          'exitCommitted=$_exitCommitted edge=${_edge?.name ?? 'none'}',
    );
    super.dispose();
  }

  /// 构建祖先级边缘识别器和不参与命中的轻量反馈层。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 当前阅读器占据的物理视口宽度。
        final double viewportWidth = constraints.maxWidth;
        /// 当前阅读器占据的物理视口高度。
        final double viewportHeight = constraints.maxHeight;
        /// 系统在左右两侧保留的原生手势区域。
        final EdgeInsets systemGestureInsets =
            MediaQuery.of(context).systemGestureInsets;
        /// 左侧候选命中宽度，最多向正文内扩展到 32 logical px。
        final double leftEdgeWidth = math
            .max(24, systemGestureInsets.left + 6)
            .clamp(24, 32)
            .toDouble();
        /// 右侧候选命中宽度，最多向正文内扩展到 32 logical px。
        final double rightEdgeWidth = math
            .max(24, systemGestureInsets.right + 6)
            .clamp(24, 32)
            .toDouble();
        /// 当前屏幕退出所需的距离，兼顾手机误触和大屏可达性。
        final double commitDistance =
            (viewportWidth * 0.18).clamp(56, 96).toDouble();
        /// 开关关闭或已经提交退出后不再注册识别器。
        final bool recognizesGesture =
            (widget.leftEnabled || widget.rightEnabled) &&
            !_exitCommitted &&
            viewportWidth > 0;
        /// 【FLUTTER_REWRITE_DEBUG_LOG】当前识别器注册状态与物理边缘宽度的稳定摘要。
        final String loggedConfiguration =
            'leftEnabled=${widget.leftEnabled} '
            'rightEnabled=${widget.rightEnabled} '
            'recognizes=$recognizesGesture '
            'exitCommitted=$_exitCommitted '
            'viewport=${viewportWidth.toStringAsFixed(1)}x'
            '${viewportHeight.toStringAsFixed(1)} '
            'systemInsets=${systemGestureInsets.left.toStringAsFixed(1)}/'
            '${systemGestureInsets.right.toStringAsFixed(1)} '
            'edgeWidths=${leftEdgeWidth.toStringAsFixed(1)}/'
            '${rightEdgeWidth.toStringAsFixed(1)} '
            'commitDistance=${commitDistance.toStringAsFixed(1)}';
        if (_lastLoggedConfiguration != loggedConfiguration) {
          _lastLoggedConfiguration = loggedConfiguration;
          // FLUTTER_REWRITE_DEBUG_LOG：布局或开关变化时记录一次，不在拖动重建期间重复输出。
          widget.logger.info(
            tag: readerEdgeSwipeExitLogTag,
            message: '$readerEdgeSwipeExitDebugLogMarker recognizerConfig '
                '$loggedConfiguration',
          );
        }
        /// 当前需要注册的手势识别器工厂。
        final Map<Type, GestureRecognizerFactory> gestures =
            recognizesGesture
            ? <Type, GestureRecognizerFactory>{
                _ReaderEdgeHorizontalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _ReaderEdgeHorizontalDragGestureRecognizer
                    >(
                      () => _ReaderEdgeHorizontalDragGestureRecognizer(
                        logger: widget.logger,
                        debugOwner: this,
                      ),
                      (
                        _ReaderEdgeHorizontalDragGestureRecognizer recognizer,
                      ) {
                        recognizer
                          ..viewportWidth = viewportWidth
                          ..leftEdgeWidth = leftEdgeWidth
                          ..rightEdgeWidth = rightEdgeWidth
                          ..leftEnabled = widget.leftEnabled
                          ..rightEnabled = widget.rightEnabled
                          // 使用原始按下位置生成 DragStartDetails，避免手指移入正文后才回调
                          // onStart，导致左边缘被误判成右边缘。
                          ..dragStartBehavior = DragStartBehavior.down
                          ..gestureSettings = const DeviceGestureSettings(
                            touchSlop: _edgeTouchSlop,
                          )
                          ..onStart = (DragStartDetails details) {
                            _handleDragStart(
                              details,
                              viewportWidth: viewportWidth,
                              leftEdgeWidth: leftEdgeWidth,
                              rightEdgeWidth: rightEdgeWidth,
                            );
                          }
                          ..onUpdate = (DragUpdateDetails details) {
                            _handleDragUpdate(details, commitDistance);
                          }
                          ..onEnd = (DragEndDetails details) {
                            _handleDragEnd(details, commitDistance);
                          }
                          ..onCancel = _handleDragCancel;
                      },
                    ),
              }
            : <Type, GestureRecognizerFactory>{};
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          excludeFromSemantics: true,
          gestures: gestures,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              widget.child,
              _buildFeedback(context, viewportHeight),
            ],
          ),
        );
      },
    );
  }

  /// 根据按下位置记录左侧或右侧候选，并显示起手反馈。
  void _handleDragStart(
    DragStartDetails details, {
    required double viewportWidth,
    required double leftEdgeWidth,
    required double rightEdgeWidth,
  }) {
    if (_exitCommitted) {
      // FLUTTER_REWRITE_DEBUG_LOG：提交后出现新的开始回调表示旧识别器仍在派发，需要在日志中暴露。
      widget.logger.warning(
        tag: readerEdgeSwipeExitLogTag,
        message: '$readerEdgeSwipeExitDebugLogMarker edgeDragStartIgnored '
            'reason=exitCommitted',
      );
      return;
    }
    /// 水平起手位置。
    final double x = details.localPosition.dx;
    /// 本次命中的物理边缘。
    final ReaderExitEdge edge = x <= leftEdgeWidth
        ? ReaderExitEdge.left
        : ReaderExitEdge.right;
    _dragUpdateLogged = false;
    // FLUTTER_REWRITE_DEBUG_LOG：onStart 只会在边缘识别器赢得横向手势竞技场后出现。
    widget.logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker edgeDragStart '
          'edge=${edge.name} x=${x.toStringAsFixed(1)} '
          'y=${details.localPosition.dy.toStringAsFixed(1)} '
          'viewportWidth=${viewportWidth.toStringAsFixed(1)} '
          'edgeWidths=${leftEdgeWidth.toStringAsFixed(1)}/'
          '${rightEdgeWidth.toStringAsFixed(1)}',
    );
    setState(() {
      _edge = edge;
      _horizontalDistance = 0;
      _feedbackProgress = 0;
      _feedbackY = details.localPosition.dy;
      _feedbackVisible = true;
    });
  }

  /// 累积位移并只把从对应边缘向屏幕内部的距离映射为反馈进度。
  void _handleDragUpdate(
    DragUpdateDetails details,
    double commitDistance,
  ) {
    final ReaderExitEdge? edge = _edge;
    if (edge == null || _exitCommitted) {
      return;
    }
    _horizontalDistance += details.primaryDelta ?? details.delta.dx;
    /// 将左右两侧镜像手势归一化为正数表示向屏幕内部滑动。
    final double inwardDistance = _normalizedInwardDistance(
      edge,
      _horizontalDistance,
    );
    if (!_dragUpdateLogged) {
      _dragUpdateLogged = true;
      // FLUTTER_REWRITE_DEBUG_LOG：只记录首个跟手更新，证明识别器获胜后确实持续收到移动事件。
      widget.logger.info(
        tag: readerEdgeSwipeExitLogTag,
        message: '$readerEdgeSwipeExitDebugLogMarker edgeDragFirstUpdate '
            'edge=${edge.name} '
            'delta=${details.delta.dx.toStringAsFixed(1)} '
            'distance=${_horizontalDistance.toStringAsFixed(1)} '
            'inward=${inwardDistance.toStringAsFixed(1)} '
            'commitDistance=${commitDistance.toStringAsFixed(1)}',
      );
    }
    setState(() {
      _feedbackProgress = (inwardDistance / commitDistance)
          .clamp(0, 1)
          .toDouble();
    });
  }

  /// 根据距离或正确方向速度提交一次退出，否则只取消本次边缘候选。
  void _handleDragEnd(DragEndDetails details, double commitDistance) {
    final ReaderExitEdge? edge = _edge;
    if (edge == null || _exitCommitted) {
      return;
    }
    /// 当前累计的正确方向距离。
    final double inwardDistance = _normalizedInwardDistance(
      edge,
      _horizontalDistance,
    );
    /// 将左右两侧速度统一成正数表示向屏幕内部。
    final double inwardVelocity = _normalizedInwardDistance(
      edge,
      details.primaryVelocity ?? 0,
    );
    /// 达到受控距离，或快速甩动且超过普通触摸松弛距离时提交退出。
    final bool shouldCommit =
        inwardDistance >= commitDistance ||
        (inwardVelocity >= _commitVelocity &&
            inwardDistance >= kTouchSlop);
    // FLUTTER_REWRITE_DEBUG_LOG：结束日志是判断退出阈值是否错误的核心证据。
    widget.logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker edgeDragEnd '
          'edge=${edge.name} '
          'distance=${_horizontalDistance.toStringAsFixed(1)} '
          'inward=${inwardDistance.toStringAsFixed(1)} '
          'velocity=${inwardVelocity.toStringAsFixed(1)} '
          'commitDistance=${commitDistance.toStringAsFixed(1)} '
          'commit=$shouldCommit',
    );
    if (shouldCommit) {
      setState(() {
        _feedbackProgress = 1;
        _feedbackVisible = true;
        _exitCommitted = true;
      });
      // FLUTTER_REWRITE_DEBUG_LOG：该日志之后应紧跟 ViewModel closeIntentAccepted 与关闭 Effect。
      widget.logger.info(
        tag: readerEdgeSwipeExitLogTag,
        message: '$readerEdgeSwipeExitDebugLogMarker edgeExitCallback',
      );
      widget.onExit();
      return;
    }
    _resetFeedback();
  }

  /// 系统或其他手势取消当前指针时隐藏反馈并保持阅读页面不变。
  void _handleDragCancel() {
    if (_exitCommitted) {
      return;
    }
    // FLUTTER_REWRITE_DEBUG_LOG：通常表示边缘识别器输给了纵向滚动、系统手势或下层组件。
    widget.logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker edgeDragCancel '
          'edge=${_edge?.name ?? 'none'} '
          'distance=${_horizontalDistance.toStringAsFixed(1)}',
    );
    _resetFeedback();
  }

  /// 清理未提交的边缘候选，不把取消动作补判为普通翻页。
  void _resetFeedback() {
    if (!mounted) {
      return;
    }
    setState(() {
      _horizontalDistance = 0;
      _feedbackProgress = 0;
      _feedbackVisible = false;
    });
    _dragUpdateLogged = false;
  }

  /// 把左右边缘的水平位移统一为向内为正、向外为负。
  double _normalizedInwardDistance(
    ReaderExitEdge edge,
    double horizontalValue,
  ) {
    return edge == ReaderExitEdge.left
        ? horizontalValue
        : -horizontalValue;
  }

  /// 构建只占小范围重绘的方向箭头，不参与正文命中和辅助功能节点。
  Widget _buildFeedback(BuildContext context, double viewportHeight) {
    /// 没有候选时沿用左侧占位，透明状态不会显示。
    final ReaderExitEdge edge = _edge ?? ReaderExitEdge.left;
    /// 图标中心避开屏幕上下边缘。
    final double top = (_feedbackY - 24)
        .clamp(8, math.max(8, viewportHeight - 56))
        .toDouble();
    /// 提示随有效退出进度向屏幕内移动的距离。
    final double inwardOffset = 6 + _feedbackProgress * 18;
    /// 达到提交阈值后使用强调容器色。
    final Color backgroundColor = _feedbackProgress >= 1
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    /// 达到提交阈值后使用强调前景色。
    final Color foregroundColor = _feedbackProgress >= 1
        ? Theme.of(context).colorScheme.onPrimaryContainer
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Positioned(
      left: edge == ReaderExitEdge.left ? inwardOffset : null,
      right: edge == ReaderExitEdge.right ? inwardOffset : null,
      top: top,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: AnimatedOpacity(
              opacity: _feedbackVisible ? 1 : 0,
              duration: DurationToken.short,
              curve: AnimationToken.standard,
              child: Transform.scale(
                scale: 0.9 + _feedbackProgress * 0.1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(
                      edge == ReaderExitEdge.left
                          ? Icons.arrow_forward
                          : Icons.arrow_back,
                      color: foregroundColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 只把物理边缘起手指针加入水平拖动竞技场，非边缘按下完全交给正文。
final class _ReaderEdgeHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  /// 创建边缘限定水平拖动识别器。
  _ReaderEdgeHorizontalDragGestureRecognizer({
    required this.logger,
    super.debugOwner,
  });

  /// 【FLUTTER_REWRITE_DEBUG_LOG】记录原始指针命中与手势竞技场胜负的统一日志接口。
  final AppLogger logger;

  /// 当前祖先手势区域的完整宽度。
  double viewportWidth = 0;

  /// 左侧允许进入竞技场的边缘宽度。
  double leftEdgeWidth = 24;

  /// 右侧允许进入竞技场的边缘宽度。
  double rightEdgeWidth = 24;

  /// 当前是否允许左侧物理边缘加入退出手势竞技场。
  bool leftEnabled = true;

  /// 当前是否允许右侧物理边缘加入退出手势竞技场。
  bool rightEnabled = false;

  /// 只跟踪从左右候选区域按下的指针，避免普通正文翻页承担额外竞争。
  @override
  void addAllowedPointer(PointerDownEvent event) {
    /// 指针相对阅读器物理视口的水平位置。
    final double x = event.localPosition.dx;
    /// 本次按下是否命中当前已开启的左侧物理边缘。
    final bool isEnabledLeftEdge =
        leftEnabled && x <= leftEdgeWidth;
    /// 本次按下是否命中当前已开启的右侧物理边缘。
    final bool isEnabledRightEdge =
        rightEnabled && x >= viewportWidth - rightEdgeWidth;
    /// 【FLUTTER_REWRITE_DEBUG_LOG】本次按下是否位于允许加入竞技场的左右边缘范围。
    final bool isEdgePointer =
        viewportWidth > 0 &&
        (isEnabledLeftEdge || isEnabledRightEdge);
    // FLUTTER_REWRITE_DEBUG_LOG：该日志出现即证明 RawGestureDetector 已命中并收到 PointerDown。
    logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker pointerDown '
          'pointer=${event.pointer} kind=${event.kind.name} '
          'x=${x.toStringAsFixed(1)} '
          'viewportWidth=${viewportWidth.toStringAsFixed(1)} '
          'edgeWidths=${leftEdgeWidth.toStringAsFixed(1)}/'
          '${rightEdgeWidth.toStringAsFixed(1)} '
          'enabledSides=$leftEnabled/$rightEnabled '
          'allowed=$isEdgePointer',
    );
    if (!isEdgePointer) {
      return;
    }
    super.addAllowedPointer(event);
  }

  /// 【FLUTTER_REWRITE_DEBUG_LOG】记录边缘识别器赢得指定指针的手势竞技场。
  @override
  void acceptGesture(int pointer) {
    // FLUTTER_REWRITE_DEBUG_LOG：若随后出现 edgeDragStart，说明胜出回调链完整。
    logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker arenaAccepted '
          'pointer=$pointer',
    );
    super.acceptGesture(pointer);
  }

  /// 【FLUTTER_REWRITE_DEBUG_LOG】记录边缘识别器输给系统、正文翻页或纵向滚动的手势竞技场。
  @override
  void rejectGesture(int pointer) {
    // FLUTTER_REWRITE_DEBUG_LOG：结合 simulationDragStart 或 pageViewDragStart 判断实际获胜方。
    logger.info(
      tag: readerEdgeSwipeExitLogTag,
      message: '$readerEdgeSwipeExitDebugLogMarker arenaRejected '
          'pointer=$pointer',
    );
    super.rejectGesture(pointer);
  }
}
