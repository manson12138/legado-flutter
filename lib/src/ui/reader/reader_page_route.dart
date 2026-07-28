import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/reader_transition_spec.dart';
import '../../domain/model/book.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';

/// 使用单次封面几何创建阅读器进入与返回动画。
final class ReaderPageRoute extends PageRouteBuilder<void> {
  /// 创建最长 300ms 的阅读器专用路由。
  ReaderPageRoute({
    required RouteSettings settings,
    required WidgetBuilder builder,
    required Book? book,
    required ReaderTransitionSpec transitionSpec,
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
           /// PDF 首批只做中心缩放淡入，不执行 3D 合页。
           final bool opensCover =
               transitionSpec.kind != ReaderTransitionKind.fallback &&
               !(book?.origin == 'loc_book' &&
                   book?.originName.toLowerCase().endsWith('.pdf') == true);
           return _ReaderRouteTransition(
             animation: animation,
             spec: transitionSpec,
             book: book,
             opensCover: opensCover,
             child: child,
           );
         },
       );
}

/// 只在路由动画期间组合页面透明度和封面隔离层。
final class _ReaderRouteTransition extends StatelessWidget {
  /// 创建阅读转场帧。
  const _ReaderRouteTransition({
    required this.animation,
    required this.spec,
    required this.book,
    required this.opensCover,
    required this.child,
  });

  /// Navigator 提供的进入或返回进度。
  final Animation<double> animation;

  /// 本次点击的短生命周期几何。
  final ReaderTransitionSpec spec;

  /// 用于封面语义和跨页面图片缓存的书籍快照。
  final Book? book;

  /// 是否允许执行 3D 合页；PDF 为 false。
  final bool opensCover;

  /// 已经构建的阅读页面，动画期间作为稳定 child 复用。
  final Widget child;

  /// 构建减少动态效果降级或完整封面动画。
  @override
  Widget build(BuildContext context) {
    /// 系统辅助功能是否要求减少动画。
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    /// 返回时不复用进入时的旧 cell 矩形，只让阅读页短暂淡出。
    if (animation.status == AnimationStatus.reverse) {
      final Animation<double> reverseOpacity = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: reverseOpacity,
        child: child,
      );
    }
    if (reduceMotion) {
      /// 300ms 路由中的前 50% 完成淡入，实际动态时间约 150ms。
      final Animation<double> reducedOpacity = CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.5, curve: Curves.easeOut),
        reverseCurve: const Interval(0, 0.5, curve: Curves.easeIn),
      );
      return FadeTransition(
        opacity: reducedOpacity,
        child: child,
      );
    }
    /// 书架、历史和无来源兼容入口使用封面接近全屏后才淡出的新动画。
    final bool usesFullScreenCover =
        spec.kind != ReaderTransitionKind.detail;
    if (usesFullScreenCover) {
      return _buildFullScreenCoverTransition(context);
    }
    return _buildCenteredCoverTransition(context);
  }

  /// 构建从真实 cell 封面放大到全屏，并在末段淡出露出文章的进入动画。
  Widget _buildFullScreenCoverTransition(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (BuildContext context, Widget? stableChild) {
        /// 当前原始路由进度。
        final double progress = animation.value.clamp(0, 1).toDouble();
        /// 前 87% 时间完成几何变化，约 200ms 时已经达到约 98% 的全屏进度。
        final double moveProgress = _intervalProgress(
          progress,
          0,
          0.87,
          Curves.easeOutCubic,
        );
        /// 只有封面接近全屏后才开始淡出并逐步显现阅读页面。
        final double revealProgress = _intervalProgress(
          progress,
          0.67,
          1,
          Curves.easeInOutCubic,
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
            final Rect? requestedSourceRect = spec.sourceRect;
            /// 来源无效时从屏幕中心的标准封面尺寸开始降级放大。
            final Rect sourceRect =
                requestedSourceRect != null &&
                    _usableSourceRect(requestedSourceRect, viewport)
                ? requestedSourceRect
                : _targetRect(viewport);
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
                          key: ValueKey<String>(spec.id),
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
                              coverUrl: spec.coverUrl,
                              semanticLabel:
                                  '${book?.name ?? '目标书籍'}封面转场',
                              bookName: book?.name,
                              bookAuthor: book?.author,
                              fit: BoxFit.cover,
                              borderRadius: coverRadius,
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

  /// 保留书籍详情入口的轻量中心开封动画，不改变本次任务以外的视觉行为。
  Widget _buildCenteredCoverTransition(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (BuildContext context, Widget? stableChild) {
        /// 当前原始路由进度。
        final double progress = animation.value.clamp(0, 1).toDouble();
        /// 阅读页面在封面开始打开后平滑显现。
        final double pageOpacity = _intervalProgress(
          progress,
          0.28,
          1,
          Curves.easeOutCubic,
        );
        /// 来源封面移动到阅读中心的进度。
        final double moveProgress = _intervalProgress(
          progress,
          0,
          0.58,
          Curves.easeOutCubic,
        );
        /// 封面以左侧书脊为轴打开的进度。
        final double openProgress = opensCover
            ? _intervalProgress(
                progress,
                0.22,
                0.84,
                Curves.easeInOutCubic,
              )
            : 0;
        /// 封面末段淡出。
        final double coverOpacity =
            1 -
            _intervalProgress(
              progress,
              0.78,
              1,
              Curves.easeOut,
            );
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            /// 当前路由可用尺寸。
            final Size viewport = constraints.biggest;
            /// 封面在阅读器中心的目标矩形。
            final Rect targetRect = _targetRect(viewport);
            /// 来源矩形无效时使用中心缩小矩形降级。
            final Rect sourceRect = _usableSourceRect(
              spec.sourceRect,
              viewport,
            )
                ? spec.sourceRect ??
                      _centeredSourceRect(targetRect)
                : _centeredSourceRect(targetRect);
            /// 当前帧封面位置和尺寸。
            final Rect coverRect = _interpolateRect(
              sourceRect,
              targetRect,
              moveProgress,
            );
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Opacity(
                  opacity: pageOpacity,
                  child: stableChild ?? const SizedBox.shrink(),
                ),
                if (coverOpacity > 0.001)
                  Positioned.fromRect(
                    rect: coverRect,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: coverOpacity,
                        child: RepaintBoundary(
                          key: ValueKey<String>(spec.id),
                          child: Transform(
                            alignment: Alignment.centerLeft,
                            transform: Matrix4.identity()
                              ..setEntry(3, 2, 0.0012)
                              ..rotateY(-math.pi * 0.47 * openProgress),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha:
                                          0.22 *
                                          (1 - openProgress * 0.5),
                                    ),
                                    blurRadius: 14,
                                    offset: const Offset(4, 2),
                                  ),
                                ],
                              ),
                              child: BookCover(
                                coverUrl: spec.coverUrl,
                                semanticLabel:
                                    '${book?.name ?? '目标书籍'}封面转场',
                                bookName: book?.name,
                                bookAuthor: book?.author,
                                borderRadius: BorderRadius.circular(10),
                              ),
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

  /// 无来源几何时从目标中心的较小封面开始。
  Rect _centeredSourceRect(Rect target) {
    return Rect.fromCenter(
      center: target.center,
      width: target.width * 0.76,
      height: target.height * 0.76,
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
