import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/reader_transition_spec.dart';
import '../../domain/model/book.dart';
import '../../help/logging/app_logger.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';

/// 使用单次封面几何创建书架、历史与兼容入口的阅读器进入和返回动画。
final class ReaderPageRoute extends PageRouteBuilder<void> {
  /// 创建最长 300ms 的阅读器专用路由。
  ReaderPageRoute({
    required RouteSettings settings,
    required WidgetBuilder builder,
    required Book? book,
    required ReaderTransitionSpec transitionSpec,
    required AppLogger logger,
  }) : super(
         settings: settings,
         transitionDuration: const Duration(milliseconds: 300),
         reverseTransitionDuration: const Duration(milliseconds: 200),
         pageBuilder: (
           BuildContext context,
           Animation<double> animation,
           Animation<double> secondaryAnimation,
         ) {
           return builder(context);
         },
         transitionsBuilder: (
           BuildContext context,
           Animation<double> animation,
           Animation<double> secondaryAnimation,
           Widget child,
         ) {
           return _ReaderRouteTransition(
             animation: animation,
             spec: transitionSpec,
             book: book,
             logger: logger,
             child: child,
           );
         },
       );
}

/// 只在路由动画期间组合页面透明度、封面隔离层和临时性能采样。
final class _ReaderRouteTransition extends StatefulWidget {
  /// 创建阅读转场帧。
  const _ReaderRouteTransition({
    required this.animation,
    required this.spec,
    required this.book,
    required this.logger,
    required this.child,
  });

  /// Navigator 提供的进入或返回进度。
  final Animation<double> animation;

  /// 本次点击的短生命周期几何。
  final ReaderTransitionSpec spec;

  /// 用于封面语义和跨页面图片缓存的书籍快照。
  final Book? book;

  /// FLUTTER_REWRITE_DEBUG_LOG：记录本轮转场帧耗时且不输出书籍或封面隐私。
  final AppLogger logger;

  /// 已经构建的阅读页面，动画期间作为稳定 child 复用。
  final Widget child;

  /// FLUTTER_REWRITE_DEBUG_LOG：创建持有临时性能采样状态的转场 State。
  @override
  State<_ReaderRouteTransition> createState() =>
      _ReaderRouteTransitionState();
}

/// 持有阅读转场渲染和本轮临时性能采样，路由释放时完整移除监听。
final class _ReaderRouteTransitionState
    extends State<_ReaderRouteTransition> {
  /// FLUTTER_REWRITE_DEBUG_LOG：兼顾 120Hz 屏幕，任一主要阶段达到 8ms 即计入汇总。
  static const int _diagnosticFrameMicroseconds = 8000;

  /// FLUTTER_REWRITE_DEBUG_LOG：单帧达到 16ms 才单独写日志，减少日志本身对动画的干扰。
  static const int _loggedFrameMicroseconds = 16000;

  /// FLUTTER_REWRITE_DEBUG_LOG：转场完成后继续收集少量尾帧，等待 FrameTiming 回调送达。
  static const Duration _timingCollectionTail =
      Duration(milliseconds: 200);

  /// FLUTTER_REWRITE_DEBUG_LOG：本轮诊断窗口的实际墙钟计时。
  final Stopwatch _diagnosticStopwatch = Stopwatch();

  /// FLUTTER_REWRITE_DEBUG_LOG：动画完成后的延迟汇总定时器。
  Timer? _diagnosticFinishTimer;

  /// FLUTTER_REWRITE_DEBUG_LOG：是否已经注册全局 FrameTiming 回调。
  bool _diagnosticsStarted = false;

  /// FLUTTER_REWRITE_DEBUG_LOG：是否已经移除回调并输出最终汇总。
  bool _diagnosticsFinished = false;

  /// FLUTTER_REWRITE_DEBUG_LOG：是否已经记录真实来源矩形和 viewport。
  bool _geometryReported = false;

  /// FLUTTER_REWRITE_DEBUG_LOG：FrameTiming 回调收到的帧总数。
  int _timedFrameCount = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：build 阶段达到 8ms 的诊断帧数。
  int _slowBuildFrameCount = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：raster 阶段达到 8ms 的诊断帧数。
  int _slowRasterFrameCount = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：总跨度达到 8ms 的诊断帧数。
  int _slowTotalFrameCount = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：采样窗口内最大的 build 微秒数。
  int _maximumBuildMicroseconds = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：采样窗口内最大的 raster 微秒数。
  int _maximumRasterMicroseconds = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：采样窗口内最大的整帧总跨度微秒数。
  int _maximumTotalMicroseconds = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：转场封面同步本地缓存检查的调用次数。
  int _cacheLookupCount = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：同步本地缓存检查累计占用的 UI isolate 微秒数。
  int _cacheLookupTotalMicroseconds = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：单次同步本地缓存检查的最大 UI isolate 微秒数。
  int _cacheLookupMaximumMicroseconds = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：动画期间网络提供者与本地文件提供者的切换次数。
  int _cacheSourceSwitchCount = 0;

  /// FLUTTER_REWRITE_DEBUG_LOG：上一帧封面本地缓存是否命中，用于识别提供者切换。
  bool? _lastCacheHit;

  /// FLUTTER_REWRITE_DEBUG_LOG：封面第一次交付已解码图片帧时的诊断窗口毫秒数。
  int? _coverFirstFrameMilliseconds;

  /// FLUTTER_REWRITE_DEBUG_LOG：封面首帧是否同步命中 Flutter 已解码图片缓存。
  bool? _coverFirstFrameSynchronouslyLoaded;

  /// FLUTTER_REWRITE_DEBUG_LOG：当前入口是否属于用户正在排查的书架或历史全屏封面转场。
  bool get _shouldCollectDiagnostics =>
      widget.spec.kind == ReaderTransitionKind.bookshelf ||
      widget.spec.kind == ReaderTransitionKind.history;

  /// FLUTTER_REWRITE_DEBUG_LOG：注册动画状态和 FrameTiming 回调；不采集详情或兼容入口。
  @override
  void initState() {
    super.initState();
    // FLUTTER_REWRITE_DEBUG_LOG：只监听当前路由持有的 animation，释放时成对移除。
    widget.animation.addStatusListener(_handleDiagnosticAnimationStatus);
    if (_shouldCollectDiagnostics &&
        widget.animation.status == AnimationStatus.forward) {
      _startDiagnostics();
    }
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：动画对象变化时迁移临时监听，避免旧路由残留回调。
  @override
  void didUpdateWidget(covariant _ReaderRouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation)) {
      // FLUTTER_REWRITE_DEBUG_LOG：日志专用动画监听迁移。
      oldWidget.animation.removeStatusListener(
        _handleDiagnosticAnimationStatus,
      );
      widget.animation.addStatusListener(_handleDiagnosticAnimationStatus);
    }
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：移除所有日志专用监听和定时器，不带到下一次转场。
  @override
  void dispose() {
    // FLUTTER_REWRITE_DEBUG_LOG：日志专用资源与路由 State 同生命周期。
    widget.animation.removeStatusListener(_handleDiagnosticAnimationStatus);
    _diagnosticFinishTimer?.cancel();
    if (_diagnosticsStarted && !_diagnosticsFinished) {
      _finishDiagnostics('disposed');
    }
    super.dispose();
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：按进入动画状态启动采样，并在完成后保留 200ms 接收尾帧。
  void _handleDiagnosticAnimationStatus(AnimationStatus status) {
    if (!_shouldCollectDiagnostics) {
      return;
    }
    if (status == AnimationStatus.forward) {
      _startDiagnostics();
      return;
    }
    if (status == AnimationStatus.completed &&
        _diagnosticsStarted &&
        !_diagnosticsFinished) {
      widget.logger.info(
        tag: readerCoverTransitionLogTag,
        message: '$readerCoverTransitionDebugLogMarker '
            'event=animation_completed transitionId=${widget.spec.id} '
            'observedElapsedMs=${_diagnosticStopwatch.elapsedMilliseconds}',
      );
      _diagnosticFinishTimer?.cancel();
      _diagnosticFinishTimer = Timer(
        _timingCollectionTail,
        () => _finishDiagnostics('completed_with_tail'),
      );
      return;
    }
    if (status == AnimationStatus.reverse &&
        _diagnosticsStarted &&
        !_diagnosticsFinished) {
      _finishDiagnostics('reverse_started');
    }
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：开始收集当前转场窗口内的 UI、Raster 和同步封面缓存耗时。
  void _startDiagnostics() {
    if (_diagnosticsStarted || _diagnosticsFinished) {
      return;
    }
    _diagnosticsStarted = true;
    _diagnosticStopwatch.start();
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
    widget.logger.info(
      tag: readerCoverTransitionLogTag,
      message: '$readerCoverTransitionDebugLogMarker '
          'event=start transitionId=${widget.spec.id} '
          'entry=${widget.spec.kind.name} '
          'animationValue=${widget.animation.value.toStringAsFixed(3)} '
          'sourceRectPresent=${widget.spec.sourceRect != null} '
          'coverSource=${_coverSourceKind()}',
    );
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：汇总并移除 FrameTiming 回调，保证日志代码可一次完整删除。
  void _finishDiagnostics(String reason) {
    if (!_diagnosticsStarted || _diagnosticsFinished) {
      return;
    }
    _diagnosticsFinished = true;
    _diagnosticFinishTimer?.cancel();
    _diagnosticFinishTimer = null;
    SchedulerBinding.instance.removeTimingsCallback(_handleFrameTimings);
    _diagnosticStopwatch.stop();
    widget.logger.info(
      tag: readerCoverTransitionLogTag,
      message: '$readerCoverTransitionDebugLogMarker '
          'event=summary transitionId=${widget.spec.id} reason=$reason '
          'windowMs=${_diagnosticStopwatch.elapsedMilliseconds} '
          'summaryThresholdUs=$_diagnosticFrameMicroseconds '
          'loggedFrameThresholdUs=$_loggedFrameMicroseconds '
          'timedFrames=$_timedFrameCount '
          'slowBuildFrames=$_slowBuildFrameCount '
          'slowRasterFrames=$_slowRasterFrameCount '
          'slowTotalFrames=$_slowTotalFrameCount '
          'maxBuildUs=$_maximumBuildMicroseconds '
          'maxRasterUs=$_maximumRasterMicroseconds '
          'maxTotalUs=$_maximumTotalMicroseconds '
          'cacheLookups=$_cacheLookupCount '
          'cacheLookupTotalUs=$_cacheLookupTotalMicroseconds '
          'cacheLookupMaxUs=$_cacheLookupMaximumMicroseconds '
          'cacheSourceSwitches=$_cacheSourceSwitchCount '
          'lastCacheHit=${_lastCacheHit ?? false} '
          'coverFirstFrameMs=${_coverFirstFrameMilliseconds ?? -1} '
          'coverFirstFrameSync='
          '${_coverFirstFrameSynchronouslyLoaded ?? false}',
    );
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：接收 Flutter 引擎帧时序，8ms 计数且 16ms 才单独输出。
  void _handleFrameTimings(List<FrameTiming> timings) {
    if (!_diagnosticsStarted || _diagnosticsFinished) {
      return;
    }
    /// FLUTTER_REWRITE_DEBUG_LOG：引擎一次可能批量回传多个已完成帧，逐帧归入同一转场汇总。
    for (final FrameTiming timing in timings) {
      /// FLUTTER_REWRITE_DEBUG_LOG：当前帧 UI build 阶段耗时。
      final int buildMicroseconds =
          timing.buildDuration.inMicroseconds;
      /// FLUTTER_REWRITE_DEBUG_LOG：当前帧 Raster 阶段耗时。
      final int rasterMicroseconds =
          timing.rasterDuration.inMicroseconds;
      /// FLUTTER_REWRITE_DEBUG_LOG：当前帧从 vsync 到 Raster 完成的总跨度。
      final int totalMicroseconds = timing.totalSpan.inMicroseconds;
      _timedFrameCount += 1;
      _maximumBuildMicroseconds = math.max(
        _maximumBuildMicroseconds,
        buildMicroseconds,
      );
      _maximumRasterMicroseconds = math.max(
        _maximumRasterMicroseconds,
        rasterMicroseconds,
      );
      _maximumTotalMicroseconds = math.max(
        _maximumTotalMicroseconds,
        totalMicroseconds,
      );
      if (buildMicroseconds >= _diagnosticFrameMicroseconds) {
        _slowBuildFrameCount += 1;
      }
      if (rasterMicroseconds >= _diagnosticFrameMicroseconds) {
        _slowRasterFrameCount += 1;
      }
      if (totalMicroseconds >= _diagnosticFrameMicroseconds) {
        _slowTotalFrameCount += 1;
      }
      if (buildMicroseconds >= _loggedFrameMicroseconds ||
          rasterMicroseconds >= _loggedFrameMicroseconds ||
          totalMicroseconds >= _loggedFrameMicroseconds) {
        widget.logger.warning(
          tag: readerCoverTransitionLogTag,
          message: '$readerCoverTransitionDebugLogMarker '
              'event=slow_frame transitionId=${widget.spec.id} '
              'frame=$_timedFrameCount buildUs=$buildMicroseconds '
              'rasterUs=$rasterMicroseconds totalUs=$totalMicroseconds '
              'sampledAnimationValue=${widget.animation.value.toStringAsFixed(3)} '
              'sampledStatus=${widget.animation.status.name}',
        );
      }
    }
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：记录转场层每次同步封面缓存检查，不输出 URL 或文件路径。
  void _handleTransitionCacheLookup(
    Duration elapsed,
    bool cacheHit,
  ) {
    if (!_diagnosticsStarted || _diagnosticsFinished) {
      return;
    }
    /// FLUTTER_REWRITE_DEBUG_LOG：本次同步缓存检查占用的 UI isolate 微秒数。
    final int elapsedMicroseconds = elapsed.inMicroseconds;
    _cacheLookupCount += 1;
    _cacheLookupTotalMicroseconds += elapsedMicroseconds;
    _cacheLookupMaximumMicroseconds = math.max(
      _cacheLookupMaximumMicroseconds,
      elapsedMicroseconds,
    );
    /// FLUTTER_REWRITE_DEBUG_LOG：本次检查前的命中状态，仅用于判断图片提供者是否切换。
    final bool? previousCacheHit = _lastCacheHit;
    if (previousCacheHit == null) {
      widget.logger.info(
        tag: readerCoverTransitionLogTag,
        message: '$readerCoverTransitionDebugLogMarker '
            'event=first_cache_lookup transitionId=${widget.spec.id} '
            'elapsedUs=$elapsedMicroseconds cacheHit=$cacheHit '
            'animationValue=${widget.animation.value.toStringAsFixed(3)}',
      );
    } else if (previousCacheHit != cacheHit) {
      _cacheSourceSwitchCount += 1;
      widget.logger.warning(
        tag: readerCoverTransitionLogTag,
        message: '$readerCoverTransitionDebugLogMarker '
            'event=cache_source_changed transitionId=${widget.spec.id} '
            'fromCacheHit=$previousCacheHit toCacheHit=$cacheHit '
            'elapsedUs=$elapsedMicroseconds '
            'animationValue=${widget.animation.value.toStringAsFixed(3)}',
      );
    }
    _lastCacheHit = cacheHit;
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：记录转场封面第一次交付已解码图片帧的相对时间。
  void _handleTransitionImageFrame(bool wasSynchronouslyLoaded) {
    if (!_diagnosticsStarted ||
        _diagnosticsFinished ||
        _coverFirstFrameMilliseconds != null) {
      return;
    }
    _coverFirstFrameMilliseconds =
        _diagnosticStopwatch.elapsedMilliseconds;
    _coverFirstFrameSynchronouslyLoaded = wasSynchronouslyLoaded;
    widget.logger.info(
      tag: readerCoverTransitionLogTag,
      message: '$readerCoverTransitionDebugLogMarker '
          'event=cover_first_image_frame transitionId=${widget.spec.id} '
          'elapsedMs=$_coverFirstFrameMilliseconds '
          'animationValue=${widget.animation.value.toStringAsFixed(3)} '
          'cacheHit=${_lastCacheHit ?? false} '
          'synchronouslyLoaded=$wasSynchronouslyLoaded',
    );
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：只记录一次有效起点、降级状态和 viewport 尺寸。
  void _reportGeometryOnce({
    required Size viewport,
    required Rect sourceRect,
    required bool usedFallbackSource,
  }) {
    if (!_diagnosticsStarted ||
        _diagnosticsFinished ||
        _geometryReported) {
      return;
    }
    _geometryReported = true;
    widget.logger.info(
      tag: readerCoverTransitionLogTag,
      message: '$readerCoverTransitionDebugLogMarker '
          'event=geometry transitionId=${widget.spec.id} '
          'viewport=${viewport.width.toStringAsFixed(1)}x'
          '${viewport.height.toStringAsFixed(1)} '
          'sourceLeft=${sourceRect.left.toStringAsFixed(1)} '
          'sourceTop=${sourceRect.top.toStringAsFixed(1)} '
          'sourceWidth=${sourceRect.width.toStringAsFixed(1)} '
          'sourceHeight=${sourceRect.height.toStringAsFixed(1)} '
          'usedFallbackSource=$usedFallbackSource',
    );
  }

  /// FLUTTER_REWRITE_DEBUG_LOG：把封面输入收窄为无隐私的来源类别。
  String _coverSourceKind() {
    /// FLUTTER_REWRITE_DEBUG_LOG：只用于分类且不会写入日志的原始封面值。
    final String value = widget.spec.coverUrl?.trim() ?? '';
    if (value.isEmpty) {
      return 'none';
    }
    /// FLUTTER_REWRITE_DEBUG_LOG：只用于判断 scheme 且不会输出的封面 URI。
    final Uri? uri = Uri.tryParse(value);
    if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      return 'network';
    }
    if (uri?.scheme == 'file') {
      return 'file_uri';
    }
    return 'local_path_or_other';
  }

  /// 构建减少动态效果降级或书架、历史与兼容入口的完整封面动画。
  @override
  Widget build(BuildContext context) {
    /// 系统辅助功能是否要求减少动画。
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    /// 返回时不复用进入时的旧 cell 矩形，只让阅读页短暂淡出。
    if (widget.animation.status == AnimationStatus.reverse) {
      final Animation<double> reverseOpacity = CurvedAnimation(
        parent: widget.animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: reverseOpacity,
        child: widget.child,
      );
    }
    if (reduceMotion) {
      /// 300ms 路由中的前 50% 完成淡入，实际动态时间约 150ms。
      final Animation<double> reducedOpacity = CurvedAnimation(
        parent: widget.animation,
        curve: const Interval(0, 0.5, curve: Curves.easeOut),
        reverseCurve: const Interval(0, 0.5, curve: Curves.easeIn),
      );
      return FadeTransition(
        opacity: reducedOpacity,
        child: widget.child,
      );
    }
    return _buildFullScreenCoverTransition(context);
  }

  /// 构建从真实 cell 封面放大到全屏，并从动画中段渐进淡出露出文章的进入动画。
  Widget _buildFullScreenCoverTransition(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      child: RepaintBoundary(child: widget.child),
      builder: (BuildContext context, Widget? stableChild) {
        /// 当前原始路由进度。
        final double progress =
            widget.animation.value.clamp(0, 1).toDouble();
        /// 前 87% 时间完成几何变化，约 200ms 时已经达到约 98% 的全屏进度。
        final double moveProgress = _intervalProgress(
          progress,
          0,
          0.87,
          Curves.easeOutCubic,
        );
        /// 书架与历史使用用户确认的首帧提前淡出；旧兼容入口继续保留原来的末段节奏。
        final bool usesEarlyCoverReveal =
            widget.spec.kind == ReaderTransitionKind.bookshelf ||
            widget.spec.kind == ReaderTransitionKind.history;
        /// 书架与历史从点击后的动画首帧开始淡出，旧兼容入口仍从动画后段开始。
        final double revealStart = usesEarlyCoverReveal ? 0 : 0.67;
        /// 书架与历史在 200ms 完全移除封面，旧兼容入口仍在 300ms 结束淡出。
        final double revealEnd = usesEarlyCoverReveal ? 2 / 3 : 1;
        /// 书架与历史使用先快后慢的淡化，让 0～200ms 持续看见正文增加且末段平缓收尾。
        final double revealProgress = _intervalProgress(
          progress,
          revealStart,
          revealEnd,
          usesEarlyCoverReveal ? Curves.easeOut : Curves.easeInOutCubic,
        );
        /// 前段背景遮罩快速隐藏来源页面，避免移动后留下第二张原 cell 封面。
        final double scrimOpacity = _intervalProgress(
          progress,
          0,
          0.25,
          Curves.easeOutCubic,
        );
        /// 封面透明度与阅读页面显现进度相反。
        final double coverOpacity = 1 - revealProgress;
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            /// 当前路由可用尺寸。
            final Size viewport = constraints.biggest;
            /// 全屏目标矩形，包含 edge-to-edge 系统栏区域。
            final Rect targetRect = Offset.zero & viewport;
            /// 路由参数中的可空来源矩形。
            final Rect? requestedSourceRect = widget.spec.sourceRect;
            /// 当前来源是否因为无效或越界而使用了中心封面降级。
            final bool usedFallbackSource =
                requestedSourceRect == null ||
                !_usableSourceRect(requestedSourceRect, viewport);
            /// 来源无效时从屏幕中心的标准封面尺寸开始降级放大。
            final Rect sourceRect =
                !usedFallbackSource &&
                    requestedSourceRect != null
                ? requestedSourceRect
                : _targetRect(viewport);
            // FLUTTER_REWRITE_DEBUG_LOG：只记录一次无隐私几何，后续动画帧不重复写日志。
            _reportGeometryOnce(
              viewport: viewport,
              sourceRect: sourceRect,
              usedFallbackSource: usedFallbackSource,
            );
            /// 当前帧封面位置和尺寸。
            final Rect coverRect = _interpolateRect(
              sourceRect,
              targetRect,
              moveProgress,
            );
            /// cell 圆角随封面铺满屏幕逐步收敛到零。
            final BorderRadius coverRadius = BorderRadius.circular(
              10 * (1 - moveProgress),
            );
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Opacity(
                  opacity: scrimOpacity,
                  child: ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor,
                  ),
                ),
                Opacity(
                  opacity: revealProgress,
                  child: stableChild ?? const SizedBox.shrink(),
                ),
                if (coverOpacity > 0.001)
                  Positioned.fromRect(
                    rect: coverRect,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: coverOpacity,
                        child: RepaintBoundary(
                          key: ValueKey<String>(widget.spec.id),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: coverRadius,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: 0.22 * (1 - moveProgress),
                                  ),
                                  blurRadius: 14 * (1 - moveProgress),
                                  offset: Offset(
                                    4 * (1 - moveProgress),
                                    2 * (1 - moveProgress),
                                  ),
                                ),
                              ],
                            ),
                            child: BookCover(
                              coverUrl: widget.spec.coverUrl,
                              semanticLabel:
                                  '${widget.book?.name ?? '目标书籍'}封面转场',
                              bookName: widget.book?.name,
                              bookAuthor: widget.book?.author,
                              fit: BoxFit.cover,
                              borderRadius: coverRadius,
                              // FLUTTER_REWRITE_DEBUG_LOG：仅转场封面启用同步缓存检查计时。
                              onTransitionCacheLookup:
                                  _handleTransitionCacheLookup,
                              // FLUTTER_REWRITE_DEBUG_LOG：只记录转场封面第一张已解码图片帧。
                              onTransitionImageFrame:
                                  _handleTransitionImageFrame,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// 把指定区间映射到 0～1 并应用曲线。
  double _intervalProgress(
    double value,
    double start,
    double end,
    Curve curve,
  ) {
    if (value <= start) {
      return 0;
    }
    if (value >= end) {
      return 1;
    }
    return curve.transform((value - start) / (end - start));
  }

  /// 阅读器中心封面目标，竖屏稍偏上，宽屏限制最大尺寸。
  Rect _targetRect(Size viewport) {
    /// 目标封面宽度。
    final double width = math.min(
      164,
      math.max(112, viewport.width * 0.34),
    );
    /// 目标封面高度。
    final double height = width / LayoutToken.bookCoverAspectRatio;
    return Rect.fromCenter(
      center: Offset(viewport.width / 2, viewport.height * 0.42),
      width: width,
      height: height,
    );
  }

  /// 判断点击瞬间的来源矩形是否仍属于合理屏幕范围。
  bool _usableSourceRect(Rect? source, Size viewport) {
    if (source == null || source.width < 8 || source.height < 12) {
      return false;
    }
    /// 给系统栏和卡片边缘保留少量容错后的屏幕范围。
    final Rect viewportRect = Rect.fromLTWH(
      -24,
      -24,
      viewport.width + 48,
      viewport.height + 48,
    );
    return source.overlaps(viewportRect);
  }

  /// 对矩形四条边做无空值线性插值。
  Rect _interpolateRect(Rect begin, Rect end, double progress) {
    return Rect.fromLTRB(
      begin.left + (end.left - begin.left) * progress,
      begin.top + (end.top - begin.top) * progress,
      begin.right + (end.right - begin.right) * progress,
      begin.bottom + (end.bottom - begin.bottom) * progress,
    );
  }
}
