import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 使用纯 Flutter 路径裁剪和页背反射绘制 Android `SimulationPageDelegate` 仿真卷页帧。
final class ReaderSimulationPageTurnFrame extends StatelessWidget {
  /// 创建一帧仿真卷页；进度为零显示当前页，为一显示目标页。
  const ReaderSimulationPageTurnFrame({
    required this.currentPage,
    required this.targetPage,
    required this.direction,
    required this.progress,
    required this.touchYRatio,
    required this.useUpperCorner,
    required this.paperColor,
    super.key,
  });

  /// 翻页开始前完整可见的当前页。
  final Widget currentPage;

  /// 翻页完成后完整可见的目标页。
  final Widget targetPage;

  /// 翻页方向；正数进入下一页，负数返回上一页。
  final int direction;

  /// 当前翻页进度，取值范围为零到一。
  final double progress;

  /// 手势触点在页面高度中的比例，用于决定卷页折痕的垂直位置。
  final double touchYRatio;

  /// 下一页卷动是否使用右上角；上一页始终从左下侧展开。
  final bool useUpperCorner;

  /// 当前阅读纸张颜色，用于生成可辨识但不过度突出的页背。
  final Color paperColor;

  /// 按当前布局尺寸生成卷页几何和有界页面层。
  @override
  Widget build(BuildContext context) {
    /// 收窄后的动画进度。
    final double turnProgress = progress.clamp(0, 1).toDouble();
    if (turnProgress <= 0.001) {
      return currentPage;
    }
    if (turnProgress >= 0.999) {
      return targetPage;
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 当前动画实际可用尺寸。
        final Size size = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        /// 上一页是下一页卷动的时间反演，并在水平方向镜像几何。
        final double geometryProgress = direction < 0
            ? 1 - turnProgress
            : turnProgress;
        /// 当前实际被折叠的纸张。
        final Widget foldingPage = direction < 0 ? targetPage : currentPage;
        /// 当前折叠纸张下方保持完整的页面。
        final Widget backgroundPage = direction < 0
            ? currentPage
            : targetPage;
        /// 当前帧的安全贝塞尔几何。
        final _ReaderSimulationGeometry? geometry =
            _ReaderSimulationGeometry.calculate(
          size: size,
          progress: geometryProgress,
          touchYRatio: touchYRatio,
          useUpperCorner: direction > 0 && useUpperCorner,
          mirrorHorizontally: direction < 0,
        );
        if (geometry == null) {
          return _buildCoverFallback(
            size: size,
            turnProgress: turnProgress,
          );
        }
        /// 动画纸张使用 RepaintBoundary 隔离正文排版和路径帧更新。
        final Widget isolatedFoldingPage = RepaintBoundary(
          child: foldingPage,
        );
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              RepaintBoundary(child: backgroundPage),
              ClipPath(
                clipper: _ReaderSimulationPathClipper(
                  geometry.remainingFrontPath,
                ),
                clipBehavior: Clip.antiAlias,
                child: isolatedFoldingPage,
              ),
              ExcludeSemantics(
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: _ReaderSimulationPathClipper(
                      geometry.foldBackPath,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        Color.alphaBlend(
                          Colors.white.withValues(alpha: 0.38),
                          paperColor,
                        ),
                        BlendMode.modulate,
                      ),
                      child: Transform(
                        transform: geometry.reflectionMatrix,
                        child: isolatedFoldingPage,
                      ),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _ReaderSimulationShadowPainter(
                    geometry: geometry,
                    paperColor: paperColor,
                    direction: direction,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 几何遇到极端无效输入时回退为现有覆盖语义，保证页码和进度不受影响。
  Widget _buildCoverFallback({
    required Size size,
    required double turnProgress,
  }) {
    if (direction > 0) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          targetPage,
          Transform.translate(
            offset: Offset(-size.width * turnProgress, 0),
            child: currentPage,
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        currentPage,
        Transform.translate(
          offset: Offset(-size.width * (1 - turnProgress), 0),
          child: targetPage,
        ),
      ],
    );
  }
}

/// 保存一帧卷页所需的有限路径、折线和页背反射矩阵。
final class _ReaderSimulationGeometry {
  /// 创建已经通过有限值检查的仿真卷页几何。
  const _ReaderSimulationGeometry({
    required this.remainingFrontPath,
    required this.foldPath,
    required this.foldBackPath,
    required this.foldStart,
    required this.foldEnd,
    required this.reflectionMatrix,
  });

  /// 当前纸张尚未卷起、仍应显示正面的区域。
  final Path remainingFrontPath;

  /// 当前纸张从正面离开的完整卷起区域。
  final Path foldPath;

  /// 当前纸张背面实际可见的闭合区域。
  final Path foldBackPath;

  /// 折痕在第一条页面边界上的起点。
  final Offset foldStart;

  /// 折痕在第二条页面边界上的终点。
  final Offset foldEnd;

  /// 把纸张正面沿折痕反射为页背的二维矩阵。
  final Matrix4 reflectionMatrix;

  /// 对齐 Android `SimulationPageDelegate.calcPoints` 生成受控贝塞尔卷页几何。
  static _ReaderSimulationGeometry? calculate({
    required Size size,
    required double progress,
    required double touchYRatio,
    required bool useUpperCorner,
    required bool mirrorHorizontally,
  }) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 1 ||
        size.height <= 1) {
      return null;
    }
    /// 防止触点与页角完全重合后产生除零的最小距离。
    const double epsilon = 0.1;
    /// 当前页面宽度。
    final double width = size.width;
    /// 当前页面高度。
    final double height = size.height;
    /// 收窄后的卷页进度。
    final double safeProgress = progress.clamp(0.001, 0.999).toDouble();
    /// 规范化计算固定使用右侧页角，上一页最终镜像全部点。
    final Offset corner = Offset(
      width,
      useUpperCorner ? 0 : height,
    );
    /// 触点随进度向页面左侧外移动，确保完成帧能够完全露出目标页。
    double touchX = width - width * 1.28 * safeProgress;
    /// 触点垂直位置保持跟手，并避免精确落到页角造成退化。
    double touchY = (touchYRatio.clamp(0.01, 0.99) * height)
        .clamp(epsilon, height - epsilon)
        .toDouble();
    if ((touchX - corner.dx).abs() < epsilon) {
      touchX = corner.dx - epsilon;
    }
    if ((touchY - corner.dy).abs() < epsilon) {
      touchY = corner.dy == 0 ? epsilon : height - epsilon;
    }
    /// 当前受控触点。
    Offset touch = Offset(touchX, touchY);
    /// 触点与页角的中点。
    Offset middle = Offset(
      (touch.dx + corner.dx) / 2,
      (touch.dy + corner.dy) / 2,
    );
    /// 第一条贝塞尔曲线控制点。
    Offset control1 = Offset(
      middle.dx -
          _safeSquare(corner.dy - middle.dy) /
              _safeDenominator(corner.dx - middle.dx),
      corner.dy,
    );
    /// 第二条贝塞尔曲线控制点。
    Offset control2 = Offset(
      corner.dx,
      middle.dy -
          _safeSquare(corner.dx - middle.dx) /
              _safeDenominator(corner.dy - middle.dy),
    );
    /// 第一条曲线与页面边缘相交的起点。
    Offset start1 = Offset(
      control1.dx - (corner.dx - control1.dx) / 2,
      corner.dy,
    );
    if (touch.dx > 0 &&
        touch.dx < width &&
        (start1.dx < 0 || start1.dx > width)) {
      /// Android 原实现会在贝塞尔起点越界时把触点拉回可绘制范围。
      final double correctedStartX = start1.dx < 0
          ? width - start1.dx
          : start1.dx;
      /// 触点到页角的水平距离。
      final double horizontalDistance =
          (corner.dx - touch.dx)
              .abs()
              .clamp(epsilon, double.infinity)
              .toDouble();
      /// 修正后的水平投影。
      final double correctedHorizontal =
          width * horizontalDistance / correctedStartX.abs().clamp(
                epsilon,
                double.infinity,
              );
      /// 修正后的垂直投影。
      final double correctedVertical =
          (corner.dx - touch.dx).abs() *
              (corner.dy - touch.dy).abs() /
              horizontalDistance;
      touch = Offset(
        (corner.dx - correctedHorizontal).abs(),
        (corner.dy - correctedVertical).abs(),
      );
      middle = Offset(
        (touch.dx + corner.dx) / 2,
        (touch.dy + corner.dy) / 2,
      );
      control1 = Offset(
        middle.dx -
            _safeSquare(corner.dy - middle.dy) /
                _safeDenominator(corner.dx - middle.dx),
        corner.dy,
      );
      control2 = Offset(
        corner.dx,
        middle.dy -
            _safeSquare(corner.dx - middle.dx) /
                _safeDenominator(corner.dy - middle.dy),
      );
      start1 = Offset(
        control1.dx - (corner.dx - control1.dx) / 2,
        corner.dy,
      );
    }
    /// 第二条曲线与页面边缘相交的起点。
    final Offset start2 = Offset(
      corner.dx,
      control2.dy - (corner.dy - control2.dy) / 2,
    );
    /// 触点控制线与两条贝塞尔起点连线的第一交点。
    final Offset end1 = _lineIntersection(
      touch,
      control1,
      start1,
      start2,
    );
    /// 触点控制线与两条贝塞尔起点连线的第二交点。
    final Offset end2 = _lineIntersection(
      touch,
      control2,
      start1,
      start2,
    );
    /// 第一条二次贝塞尔曲线的中间顶点。
    final Offset vertex1 = Offset(
      (start1.dx + 2 * control1.dx + end1.dx) / 4,
      (start1.dy + 2 * control1.dy + end1.dy) / 4,
    );
    /// 第二条二次贝塞尔曲线的中间顶点。
    final Offset vertex2 = Offset(
      (start2.dx + 2 * control2.dx + end2.dx) / 4,
      (start2.dy + 2 * control2.dy + end2.dy) / 4,
    );
    /// 本帧全部关键点，用于拒绝会使 Canvas Path 异常的输入。
    final List<Offset> points = <Offset>[
      corner,
      touch,
      control1,
      control2,
      start1,
      start2,
      end1,
      end2,
      vertex1,
      vertex2,
    ];
    if (points.any((Offset point) => !_isFiniteOffset(point))) {
      return null;
    }

    /// 按上一页方向镜像横坐标，但不镜像页面 Widget 本身。
    Offset mapPoint(Offset point) {
      return mirrorHorizontally
          ? Offset(width - point.dx, point.dy)
          : point;
    }

    /// 映射后的页角。
    final Offset mappedCorner = mapPoint(corner);
    /// 映射后的触点。
    final Offset mappedTouch = mapPoint(touch);
    /// 映射后的第一控制点。
    final Offset mappedControl1 = mapPoint(control1);
    /// 映射后的第二控制点。
    final Offset mappedControl2 = mapPoint(control2);
    /// 映射后的第一曲线起点。
    final Offset mappedStart1 = mapPoint(start1);
    /// 映射后的第二曲线起点。
    final Offset mappedStart2 = mapPoint(start2);
    /// 映射后的第一曲线终点。
    final Offset mappedEnd1 = mapPoint(end1);
    /// 映射后的第二曲线终点。
    final Offset mappedEnd2 = mapPoint(end2);
    /// 映射后的第一曲线顶点。
    final Offset mappedVertex1 = mapPoint(vertex1);
    /// 映射后的第二曲线顶点。
    final Offset mappedVertex2 = mapPoint(vertex2);

    /// 当前纸张已经离开正面的卷起路径。
    final Path foldPath = Path()
      ..moveTo(mappedStart1.dx, mappedStart1.dy)
      ..quadraticBezierTo(
        mappedControl1.dx,
        mappedControl1.dy,
        mappedEnd1.dx,
        mappedEnd1.dy,
      )
      ..lineTo(mappedTouch.dx, mappedTouch.dy)
      ..lineTo(mappedEnd2.dx, mappedEnd2.dy)
      ..quadraticBezierTo(
        mappedControl2.dx,
        mappedControl2.dy,
        mappedStart2.dx,
        mappedStart2.dy,
      )
      ..lineTo(mappedCorner.dx, mappedCorner.dy)
      ..close();
    /// 当前纸张实际显示页背的内部路径。
    final Path foldBackPath = Path()
      ..moveTo(mappedVertex2.dx, mappedVertex2.dy)
      ..lineTo(mappedVertex1.dx, mappedVertex1.dy)
      ..lineTo(mappedEnd1.dx, mappedEnd1.dy)
      ..lineTo(mappedTouch.dx, mappedTouch.dy)
      ..lineTo(mappedEnd2.dx, mappedEnd2.dy)
      ..close();
    /// 当前纸张正面路径使用偶奇规则从页面矩形中扣除卷起区域。
    final Path remainingFrontPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(foldPath, Offset.zero);
    /// 页背沿两条曲线起点形成的折痕执行二维反射。
    final Matrix4 reflectionMatrix = _reflectionAcrossLine(
      mappedStart1,
      mappedStart2,
    );
    return _ReaderSimulationGeometry(
      remainingFrontPath: remainingFrontPath,
      foldPath: foldPath,
      foldBackPath: foldBackPath,
      foldStart: mappedStart1,
      foldEnd: mappedStart2,
      reflectionMatrix: reflectionMatrix,
    );
  }

  /// 对数值平方，集中表达贝塞尔控制点公式。
  static double _safeSquare(double value) => value * value;

  /// 避免贝塞尔控制点公式出现零分母，同时保留原符号。
  static double _safeDenominator(double value) {
    const double epsilon = 0.1;
    if (value.abs() >= epsilon) {
      return value;
    }
    return value.isNegative ? -epsilon : epsilon;
  }

  /// 使用行列式求两条无限直线交点；近平行时返回两条贝塞尔起点的中点。
  static Offset _lineIntersection(
    Offset firstStart,
    Offset firstEnd,
    Offset secondStart,
    Offset secondEnd,
  ) {
    /// 第一条直线的水平差。
    final double x1 = firstStart.dx;
    /// 第一条直线的垂直差。
    final double y1 = firstStart.dy;
    /// 第一条直线终点横坐标。
    final double x2 = firstEnd.dx;
    /// 第一条直线终点纵坐标。
    final double y2 = firstEnd.dy;
    /// 第二条直线起点横坐标。
    final double x3 = secondStart.dx;
    /// 第二条直线起点纵坐标。
    final double y3 = secondStart.dy;
    /// 第二条直线终点横坐标。
    final double x4 = secondEnd.dx;
    /// 第二条直线终点纵坐标。
    final double y4 = secondEnd.dy;
    /// 两条直线行列式分母。
    final double denominator =
        (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
    if (denominator.abs() < 0.1) {
      return Offset(
        (secondStart.dx + secondEnd.dx) / 2,
        (secondStart.dy + secondEnd.dy) / 2,
      );
    }
    /// 第一条直线的二维行列式。
    final double firstDeterminant = x1 * y2 - y1 * x2;
    /// 第二条直线的二维行列式。
    final double secondDeterminant = x3 * y4 - y3 * x4;
    return Offset(
      (firstDeterminant * (x3 - x4) -
              (x1 - x2) * secondDeterminant) /
          denominator,
      (firstDeterminant * (y3 - y4) -
              (y1 - y2) * secondDeterminant) /
          denominator,
    );
  }

  /// 生成沿任意二维直线反射页面内容的矩阵。
  static Matrix4 _reflectionAcrossLine(Offset start, Offset end) {
    /// 折痕方向角。
    final double angle = math.atan2(
      end.dy - start.dy,
      end.dx - start.dx,
    );
    /// 二倍角余弦。
    final double cosine = math.cos(angle * 2);
    /// 二倍角正弦。
    final double sine = math.sin(angle * 2);
    /// 反射后保持折痕起点不动的水平平移。
    final double translateX =
        start.dx - cosine * start.dx - sine * start.dy;
    /// 反射后保持折痕起点不动的垂直平移。
    final double translateY =
        start.dy - sine * start.dx + cosine * start.dy;
    /// Flutter 使用的列向量四阶变换矩阵。
    final Matrix4 matrix = Matrix4.identity();
    matrix
      ..setEntry(0, 0, cosine)
      ..setEntry(0, 1, sine)
      ..setEntry(1, 0, sine)
      ..setEntry(1, 1, -cosine)
      ..setEntry(0, 3, translateX)
      ..setEntry(1, 3, translateY);
    return matrix;
  }

  /// 判断坐标可安全交给 Flutter Canvas。
  static bool _isFiniteOffset(Offset point) {
    return point.dx.isFinite && point.dy.isFinite;
  }
}

/// 使用指定路径裁剪仿真页正面或页背。
final class _ReaderSimulationPathClipper extends CustomClipper<Path> {
  /// 创建不可变路径裁剪器。
  const _ReaderSimulationPathClipper(this.path);

  /// 当前帧已经计算完成的裁剪路径。
  final Path path;

  /// 返回与当前页面尺寸配套的路径。
  @override
  Path getClip(Size size) => path;

  /// 每帧路径对象不同，必须刷新裁剪层。
  @override
  bool shouldReclip(covariant _ReaderSimulationPathClipper oldClipper) {
    return oldClipper.path != path;
  }
}

/// 绘制仿真纸张背面着色、折痕和两侧有限渐变阴影。
final class _ReaderSimulationShadowPainter extends CustomPainter {
  /// 创建当前帧阴影绘制器。
  const _ReaderSimulationShadowPainter({
    required this.geometry,
    required this.paperColor,
    required this.direction,
  });

  /// 当前帧路径与折痕。
  final _ReaderSimulationGeometry geometry;

  /// 当前阅读纸张颜色。
  final Color paperColor;

  /// 当前翻页方向，用于确定阴影明暗方向。
  final int direction;

  /// 在有限路径内绘制页背和折痕阴影，不创建全屏离屏图层。
  @override
  void paint(Canvas canvas, Size size) {
    /// 页背使用阅读背景的轻微灰化色，保持不同主题下可读。
    final Paint backTintPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Color.alphaBlend(
        Colors.black.withValues(alpha: 0.055),
        paperColor.withValues(alpha: 0.82),
      );
    canvas.drawPath(geometry.foldBackPath, backTintPaint);

    /// 折痕附近的有限阴影范围。
    final Rect shadowRect = geometry.foldPath
        .getBounds()
        .inflate(24)
        .intersect(Offset.zero & size);
    if (!shadowRect.isEmpty) {
      /// 折痕阴影按翻页方向逐渐透明。
      final Paint shadowPaint = Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: direction > 0
              ? Alignment.centerRight
              : Alignment.centerLeft,
          end: direction > 0
              ? Alignment.centerLeft
              : Alignment.centerRight,
          colors: <Color>[
            Colors.black.withValues(alpha: 0.22),
            Colors.black.withValues(alpha: 0.08),
            Colors.transparent,
          ],
          stops: const <double>[0, 0.34, 1],
        ).createShader(shadowRect);
      canvas.save();
      canvas.clipPath(geometry.foldPath);
      canvas.drawRect(shadowRect, shadowPaint);
      canvas.restore();
    }

    /// 细折线用于稳定表达卷页边界，避免深色主题下页背与正面粘连。
    final Paint creasePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.black.withValues(alpha: 0.2);
    canvas.drawLine(
      geometry.foldStart,
      geometry.foldEnd,
      creasePaint,
    );
  }

  /// 路径和配色变化时刷新；动画帧不会触发正文重新分页。
  @override
  bool shouldRepaint(covariant _ReaderSimulationShadowPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.paperColor != paperColor ||
        oldDelegate.direction != direction;
  }
}
