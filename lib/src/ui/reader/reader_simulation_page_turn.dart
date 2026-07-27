import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 使用真实二维触点、贝塞尔裁剪和页背反射绘制 Android `SimulationPageDelegate` 同类卷页帧。
final class ReaderSimulationPageTurnFrame extends StatelessWidget {
  /// 创建一帧仿真卷页；进度只负责稳定首末帧，卷页几何完全由触点和页角决定。
  const ReaderSimulationPageTurnFrame({
    required this.currentPage,
    required this.targetPage,
    required this.direction,
    required this.progress,
    required this.touch,
    required this.corner,
    required this.paperColor,
    this.onDebugLog,
    super.key,
  });

  /// 翻页开始前完整可见的当前页。
  final Widget currentPage;

  /// 翻页完成后完整可见的目标页。
  final Widget targetPage;

  /// 翻页方向；正数进入下一页，负数返回上一页。
  final int direction;

  /// 当前翻页完成比例，仅用于在零和一附近返回稳定页面。
  final double progress;

  /// 当前帧直接消费的真实二维触点；完成和回弹动画会同时更新横纵坐标。
  final Offset touch;

  /// 本次手势超过松弛值后锁定的右上或右下页角。
  final Offset corner;

  /// 当前阅读纸张颜色，用于页背轻量着色。
  final Color paperColor;

  /// 【FLUTTER_READER_SIMULATION_LOG】把当前帧几何摘要交给外层统一节流和写日志。
  final ValueChanged<String>? onDebugLog;

  /// 按当前布局尺寸生成卷页几何和有界页面层。
  @override
  Widget build(BuildContext context) {
    /// 收窄后的动画完成比例。
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
        /// 当前实际被折叠的纸张；上一页是目标纸张从左侧逐步展开。
        final Widget foldingPage = direction < 0 ? targetPage : currentPage;
        /// 当前折叠纸张下方保持完整的页面。
        final Widget backgroundPage =
            direction < 0 ? currentPage : targetPage;
        /// 当前帧按 Android 控制点关系计算的安全贝塞尔几何。
        final _ReaderSimulationGeometry? geometry =
            _ReaderSimulationGeometry.calculate(
          size: size,
          touch: touch,
          corner: corner,
        );
        if (geometry == null) {
          onDebugLog?.call(
            'event=geometry_fallback direction=$direction '
            'progress=${_formatDouble(turnProgress)} '
            'size=${_formatSize(size)} inputTouch=${_formatOffset(touch)} '
            'corner=${_formatOffset(corner)}',
          );
          return _buildCoverFallback(
            size: size,
            turnProgress: turnProgress,
          );
        }
        onDebugLog?.call(
          'event=geometry direction=$direction '
          'progress=${_formatDouble(turnProgress)} '
          'size=${_formatSize(size)} inputTouch=${_formatOffset(touch)} '
          'safeTouch=${_formatOffset(geometry.touch)} '
          'corner=${_formatOffset(geometry.corner)} '
          'isRtOrLb=${geometry.isRightTopOrLeftBottom} '
          'bezierCorrected=${geometry.touchAdjustedForBezierBounds} '
          'control1=${_formatOffset(geometry.control1)} '
          'control2=${_formatOffset(geometry.control2)} '
          'start1=${_formatOffset(geometry.start1)} '
          'start2=${_formatOffset(geometry.start2)} '
          'foldBounds=${_formatRect(geometry.foldPath.getBounds())} '
          'backBounds=${_formatRect(geometry.foldBackPath.getBounds())}',
        );
        /// 当前页正面使用独立重绘边界，路径变化不重新执行正文分页。
        final Widget frontFoldingPage = RepaintBoundary(
          child: foldingPage,
        );
        /// 页背使用另一独立重绘边界；它与正面不是同一个 RenderObject。
        final Widget backFoldingPage = RepaintBoundary(
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
                child: frontFoldingPage,
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _ReaderSimulationShadowPainter(
                    geometry: geometry,
                    layer: _ReaderSimulationShadowLayer.front,
                  ),
                ),
              ),
              ExcludeSemantics(
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: _ReaderSimulationPathClipper(
                      geometry.foldBackPath,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        /// Android `drawCurrentBackArea()` 会先以阅读背景均色填满页背裁剪区，
                        /// 再绘制反射页面；这里保持相同的不透明纸张介质，避免目标页从边缘透出。
                        ColoredBox(color: paperColor),
                        Transform(
                          transform: geometry.reflectionMatrix,
                          transformHitTests: false,
                          child: backFoldingPage,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _ReaderSimulationShadowPainter(
                    geometry: geometry,
                    layer: _ReaderSimulationShadowLayer.back,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 几何整段无法安全计算时回退为覆盖语义，保证页码和进度不受影响。
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

  /// 【FLUTTER_READER_SIMULATION_LOG】把浮点数限制为一位小数，控制逐帧日志体积。
  static String _formatDouble(double value) => value.toStringAsFixed(1);

  /// 【FLUTTER_READER_SIMULATION_LOG】格式化不含正文或设备标识的二维坐标。
  static String _formatOffset(Offset value) {
    return '(${_formatDouble(value.dx)},${_formatDouble(value.dy)})';
  }

  /// 【FLUTTER_READER_SIMULATION_LOG】格式化当前动画布局尺寸。
  static String _formatSize(Size value) {
    return '(${_formatDouble(value.width)},${_formatDouble(value.height)})';
  }

  /// 【FLUTTER_READER_SIMULATION_LOG】格式化路径包围矩形，定位超长页背但不记录正文。
  static String _formatRect(Rect value) {
    return '(${_formatDouble(value.left)},${_formatDouble(value.top)},'
        '${_formatDouble(value.right)},${_formatDouble(value.bottom)})';
  }
}

/// 保存一帧卷页所需的有限路径、控制点和页背反射矩阵。
final class _ReaderSimulationGeometry {
  /// 创建已经通过有限值检查的仿真卷页几何。
  const _ReaderSimulationGeometry({
    required this.size,
    required this.remainingFrontPath,
    required this.foldPath,
    required this.foldBackPath,
    required this.targetRevealPath,
    required this.touch,
    required this.corner,
    required this.control1,
    required this.control2,
    required this.start1,
    required this.start2,
    required this.reflectionMatrix,
    required this.isRightTopOrLeftBottom,
    required this.touchToCornerDistance,
    required this.touchAdjustedForBezierBounds,
  });

  /// 当前页面尺寸。
  final Size size;

  /// 当前纸张尚未卷起、仍应显示正面的区域。
  final Path remainingFrontPath;

  /// 当前纸张从正面离开的完整卷起区域。
  final Path foldPath;

  /// 当前纸张背面实际可见的闭合区域。
  final Path foldBackPath;

  /// 目标页在卷起区域内实际露出的路径。
  final Path targetRevealPath;

  /// 经过 Android 同类越界修正后的触点。
  final Offset touch;

  /// 本次手势锁定的页角。
  final Offset corner;

  /// 第一条贝塞尔曲线控制点。
  final Offset control1;

  /// 第二条贝塞尔曲线控制点。
  final Offset control2;

  /// 第一条贝塞尔曲线起点。
  final Offset start1;

  /// 第二条贝塞尔曲线起点。
  final Offset start2;

  /// 把纸张正面沿控制点连线反射为页背的二维矩阵。
  final Matrix4 reflectionMatrix;

  /// 当前页角是否属于 Android `mIsRtOrLb` 的右上或左下方向。
  final bool isRightTopOrLeftBottom;

  /// 触点到锁定页角的距离，用于控制目标页阴影宽度。
  final double touchToCornerDistance;

  /// 【FLUTTER_READER_SIMULATION_LOG】当前帧是否进入贝塞尔起点越界后的触点联动修正分支。
  final bool touchAdjustedForBezierBounds;

  /// 对齐 Android `SimulationPageDelegate.calcPoints`，直接消费真实触点生成卷页几何。
  static _ReaderSimulationGeometry? calculate({
    required Size size,
    required Offset touch,
    required Offset corner,
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
    /// 收窄到受控扩展视口的页角。
    final Offset safeCorner = Offset(
      corner.dx.clamp(0, width).toDouble(),
      corner.dy <= height / 2 ? 0 : height,
    );
    /// 收窄到动画允许扩展范围的原始触点。
    double touchX = touch.dx.clamp(-width * 1.25, width * 1.25).toDouble();
    /// 收窄到动画允许扩展范围的原始纵坐标。
    double touchY =
        touch.dy.clamp(-height * 0.25, height * 1.25).toDouble();
    if ((touchX - safeCorner.dx).abs() < epsilon) {
      touchX = safeCorner.dx - epsilon;
    }
    if ((touchY - safeCorner.dy).abs() < epsilon) {
      touchY = safeCorner.dy == 0 ? epsilon : height - epsilon;
    }
    /// 当前受控触点。
    Offset safeTouch = Offset(touchX, touchY);
    /// 【FLUTTER_READER_SIMULATION_LOG】记录当前帧是否执行贝塞尔越界触点修正。
    bool touchAdjustedForBezierBounds = false;
    /// 触点与页角的中点。
    Offset middle = Offset(
      (safeTouch.dx + safeCorner.dx) / 2,
      (safeTouch.dy + safeCorner.dy) / 2,
    );
    /// 第一条贝塞尔曲线控制点。
    Offset control1 = Offset(
      middle.dx -
          _safeSquare(safeCorner.dy - middle.dy) /
              _safeDenominator(safeCorner.dx - middle.dx),
      safeCorner.dy,
    );
    /// 第二条贝塞尔曲线控制点。
    Offset control2 = Offset(
      safeCorner.dx,
      middle.dy -
          _safeSquare(safeCorner.dx - middle.dx) /
              _safeDenominator(safeCorner.dy - middle.dy),
    );
    /// 第一条曲线与页面边缘相交的起点。
    Offset start1 = Offset(
      control1.dx - (safeCorner.dx - control1.dx) / 2,
      safeCorner.dy,
    );
    if (safeTouch.dx > 0 &&
        safeTouch.dx < width &&
        (start1.dx < 0 || start1.dx > width)) {
      touchAdjustedForBezierBounds = true;
      /// Android 原实现会在贝塞尔起点越界时把触点拉回可绘制范围。
      final double correctedStartX =
          start1.dx < 0 ? width - start1.dx : start1.dx;
      /// 修正前触点到页角的水平距离；Android 使用它作为 X/Y 同比例收束的稳定分母。
      final double originalHorizontalDistance =
          (safeCorner.dx - safeTouch.dx)
          .abs()
          .clamp(epsilon, double.infinity)
          .toDouble();
      /// 修正后的水平投影。
      final double correctedHorizontal =
          width * originalHorizontalDistance /
              correctedStartX.abs().clamp(epsilon, double.infinity);
      /// 先得到修正后的触点横坐标；后续垂直投影必须消费这个新值。
      final double correctedTouchX =
          (safeCorner.dx - correctedHorizontal).abs();
      /// 对齐 Android `calcPoints()`：用修正后的 X 距离联动收束 Y，避免形成贯穿整页的长斜带。
      final double correctedVertical =
          (safeCorner.dx - correctedTouchX).abs() *
              (safeCorner.dy - safeTouch.dy).abs() /
              originalHorizontalDistance;
      safeTouch = Offset(
        correctedTouchX,
        (safeCorner.dy - correctedVertical).abs(),
      );
      middle = Offset(
        (safeTouch.dx + safeCorner.dx) / 2,
        (safeTouch.dy + safeCorner.dy) / 2,
      );
      control1 = Offset(
        middle.dx -
            _safeSquare(safeCorner.dy - middle.dy) /
                _safeDenominator(safeCorner.dx - middle.dx),
        safeCorner.dy,
      );
      control2 = Offset(
        safeCorner.dx,
        middle.dy -
            _safeSquare(safeCorner.dx - middle.dx) /
                _safeDenominator(safeCorner.dy - middle.dy),
      );
      start1 = Offset(
        control1.dx - (safeCorner.dx - control1.dx) / 2,
        safeCorner.dy,
      );
    }
    /// 第二条曲线与页面边缘相交的起点。
    final Offset start2 = Offset(
      safeCorner.dx,
      control2.dy - (safeCorner.dy - control2.dy) / 2,
    );
    /// 触点控制线与两条贝塞尔起点连线的第一交点。
    final Offset end1 = _lineIntersection(
      safeTouch,
      control1,
      start1,
      start2,
    );
    /// 触点控制线与两条贝塞尔起点连线的第二交点。
    final Offset end2 = _lineIntersection(
      safeTouch,
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
      safeCorner,
      safeTouch,
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
    /// 当前纸张已经离开正面的卷起路径。
    final Path foldPath = Path()
      ..moveTo(start1.dx, start1.dy)
      ..quadraticBezierTo(
        control1.dx,
        control1.dy,
        end1.dx,
        end1.dy,
      )
      ..lineTo(safeTouch.dx, safeTouch.dy)
      ..lineTo(end2.dx, end2.dy)
      ..quadraticBezierTo(
        control2.dx,
        control2.dy,
        start2.dx,
        start2.dy,
      )
      ..lineTo(safeCorner.dx, safeCorner.dy)
      ..close();
    /// 当前纸张页背的原始内部路径。
    final Path rawFoldBackPath = Path()
      ..moveTo(vertex2.dx, vertex2.dy)
      ..lineTo(vertex1.dx, vertex1.dy)
      ..lineTo(end1.dx, end1.dy)
      ..lineTo(safeTouch.dx, safeTouch.dy)
      ..lineTo(end2.dx, end2.dy)
      ..close();
    /// 对齐 Android 连续两次 `clipPath`：页背只能出现在完整卷起区域与内部页背路径的交集。
    final Path foldBackPath;
    try {
      foldBackPath = Path.combine(
        PathOperation.intersect,
        foldPath,
        rawFoldBackPath,
      );
    } on StateError {
      // 极端几何无法安全执行路径布尔运算时返回空结果，由稳定覆盖动画承接本帧。
      return null;
    }
    /// 目标页在卷起区域中露出的路径，对应 Android `drawNextPageAreaAndShadow`。
    final Path targetRevealPath = Path()
      ..moveTo(start1.dx, start1.dy)
      ..lineTo(vertex1.dx, vertex1.dy)
      ..lineTo(vertex2.dx, vertex2.dy)
      ..lineTo(start2.dx, start2.dy)
      ..lineTo(safeCorner.dx, safeCorner.dy)
      ..close();
    /// 当前纸张正面路径使用偶奇规则从页面矩形中扣除卷起区域。
    final Path remainingFrontPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(foldPath, Offset.zero);
    /// Android 页背矩阵沿两个贝塞尔控制点的连线反射，不沿曲线起点连线反射。
    final Matrix4 reflectionMatrix = _reflectionAcrossLine(
      control1,
      control2,
    );
    /// 当前页角是否属于 Android 的右上或左下方向。
    final bool isRightTopOrLeftBottom =
        (safeCorner.dx == 0 && safeCorner.dy == height) ||
            (safeCorner.dy == 0 && safeCorner.dx == width);
    /// 当前触点到页角的直线距离。
    final double touchToCornerDistance = math.sqrt(
      _safeSquare(safeTouch.dx - safeCorner.dx) +
          _safeSquare(safeTouch.dy - safeCorner.dy),
    );
    return _ReaderSimulationGeometry(
      size: size,
      remainingFrontPath: remainingFrontPath,
      foldPath: foldPath,
      foldBackPath: foldBackPath,
      targetRevealPath: targetRevealPath,
      touch: safeTouch,
      corner: safeCorner,
      control1: control1,
      control2: control2,
      start1: start1,
      start2: start2,
      reflectionMatrix: reflectionMatrix,
      isRightTopOrLeftBottom: isRightTopOrLeftBottom,
      touchToCornerDistance: touchToCornerDistance,
      touchAdjustedForBezierBounds: touchAdjustedForBezierBounds,
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

  /// 使用行列式求两条无限直线交点；近平行时返回第二条线段的中点。
  static Offset _lineIntersection(
    Offset firstStart,
    Offset firstEnd,
    Offset secondStart,
    Offset secondEnd,
  ) {
    /// 第一条直线起点横坐标。
    final double x1 = firstStart.dx;
    /// 第一条直线起点纵坐标。
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

/// 阴影绘制所在的页面层，避免目标页阴影错误盖住反射后的页背。
enum _ReaderSimulationShadowLayer {
  /// 页背之前绘制目标页阴影和卷起页两段前景阴影。
  front,

  /// 页背之后绘制页背着色和折叠阴影。
  back,
}

/// 按 Android 四组 GradientDrawable 职责绘制有限、方向一致的卷页阴影。
final class _ReaderSimulationShadowPainter extends CustomPainter {
  /// 创建当前帧指定层级的阴影绘制器。
  const _ReaderSimulationShadowPainter({
    required this.geometry,
    required this.layer,
  });

  /// 当前帧路径、控制点和触点。
  final _ReaderSimulationGeometry geometry;

  /// 本绘制器负责的阴影层级。
  final _ReaderSimulationShadowLayer layer;

  /// Android `mBackShadowColors`：目标页折痕使用深色到透明的窄渐变。
  static const List<Color> _targetPageShadowColors = <Color>[
    Color(0xFF111111),
    Color(0x00111111),
  ];

  /// Android `mFrontShadowColors`：当前页正面两段阴影使用半透明深色到透明。
  static const List<Color> _currentPageShadowColors = <Color>[
    Color(0x80111111),
    Color(0x00111111),
  ];

  /// Android 折叠阴影颜色顺序与其他阴影相反，透明端朝外、深色端贴近页背内侧。
  static const List<Color> _foldBackShadowColors = <Color>[
    Color(0x00333333),
    Color(0xB0333333),
  ];

  /// 绘制目标页/正面阴影或页背/折叠阴影，不创建全屏模糊层。
  @override
  void paint(Canvas canvas, Size size) {
    if (layer == _ReaderSimulationShadowLayer.front) {
      _drawTargetPageShadow(canvas);
      _drawCurrentPageShadows(canvas);
      return;
    }
    _drawFoldBackShadow(canvas);
  }

  /// 绘制目标页靠近折痕的动态宽度阴影。
  void _drawTargetPageShadow(Canvas canvas) {
    /// Android 目标页阴影按触点到页角距离的四分之一扩展。
    final double width = (geometry.touchToCornerDistance / 4)
        .clamp(1, geometry.size.width)
        .toDouble();
    /// 阴影带相对折痕起点的左边界。
    final double left =
        geometry.isRightTopOrLeftBottom ? 0 : -width;
    /// 阴影带相对折痕起点的右边界。
    final double right =
        geometry.isRightTopOrLeftBottom ? width : 0;
    /// Android `mDegrees` 对应的目标页阴影旋转角。
    final double angle = math.atan2(
      geometry.control1.dx - geometry.corner.dx,
      geometry.control2.dy - geometry.corner.dy,
    );
    canvas.save();
    canvas.clipPath(geometry.foldPath);
    canvas.clipPath(geometry.targetRevealPath);
    _drawRotatedBand(
      canvas,
      pivot: geometry.start1,
      angle: angle,
      rect: Rect.fromLTRB(
        left,
        0,
        right,
        _maxLength,
      ),
      horizontalGradient: true,
      reverseGradient: !geometry.isRightTopOrLeftBottom,
      colors: _targetPageShadowColors,
    );
    canvas.restore();
  }

  /// 分别沿两条贝塞尔控制边绘制卷起页正面的两段阴影。
  void _drawCurrentPageShadows(Canvas canvas) {
    /// Android 固定的前景阴影逻辑宽度。
    const double shadowWidth = 25;
    /// 用于求阴影尖端偏移的角度。
    final double degree = geometry.isRightTopOrLeftBottom
        ? math.pi / 4 -
            math.atan2(
              geometry.control1.dy - geometry.touch.dy,
              geometry.touch.dx - geometry.control1.dx,
            )
        : math.pi / 4 -
            math.atan2(
              geometry.touch.dy - geometry.control1.dy,
              geometry.touch.dx - geometry.control1.dx,
            );
    /// 阴影尖端的水平偏移。
    final double deltaX = shadowWidth * math.sqrt(2) * math.cos(degree);
    /// 阴影尖端的垂直偏移。
    final double deltaY = shadowWidth * math.sqrt(2) * math.sin(degree);
    /// 两段前景阴影共享的尖端。
    final Offset shadowTip = Offset(
      geometry.touch.dx + deltaX,
      geometry.isRightTopOrLeftBottom
          ? geometry.touch.dy + deltaY
          : geometry.touch.dy - deltaY,
    );
    /// 第一条控制边的有限裁剪路径。
    final Path firstShadowPath = Path()
      ..moveTo(shadowTip.dx, shadowTip.dy)
      ..lineTo(geometry.touch.dx, geometry.touch.dy)
      ..lineTo(geometry.control1.dx, geometry.control1.dy)
      ..lineTo(geometry.start1.dx, geometry.start1.dy)
      ..close();
    canvas.save();
    canvas.clipPath(geometry.remainingFrontPath);
    canvas.clipPath(firstShadowPath);
    /// 第一段阴影绕第一控制点旋转的角度。
    final double firstAngle = math.atan2(
      geometry.touch.dx - geometry.control1.dx,
      geometry.control1.dy - geometry.touch.dy,
    );
    _drawRotatedBand(
      canvas,
      pivot: geometry.control1,
      angle: firstAngle,
      rect: Rect.fromLTRB(
        geometry.isRightTopOrLeftBottom ? 0 : -shadowWidth,
        -_maxLength,
        geometry.isRightTopOrLeftBottom ? shadowWidth : 1,
        0,
      ),
      horizontalGradient: true,
      reverseGradient: !geometry.isRightTopOrLeftBottom,
      colors: _currentPageShadowColors,
    );
    canvas.restore();

    /// 第二条控制边的有限裁剪路径。
    final Path secondShadowPath = Path()
      ..moveTo(shadowTip.dx, shadowTip.dy)
      ..lineTo(geometry.touch.dx, geometry.touch.dy)
      ..lineTo(geometry.control2.dx, geometry.control2.dy)
      ..lineTo(geometry.start2.dx, geometry.start2.dy)
      ..close();
    canvas.save();
    canvas.clipPath(geometry.remainingFrontPath);
    canvas.clipPath(secondShadowPath);
    /// 第二段阴影绕第二控制点旋转的角度。
    final double secondAngle = math.atan2(
      geometry.control2.dy - geometry.touch.dy,
      geometry.control2.dx - geometry.touch.dx,
    );
    /// Android 第二段阴影根据控制点到页面参考边的斜距移动旋转后的水平范围。
    final double control2ReferenceY = geometry.control2.dy < 0
        ? geometry.control2.dy - geometry.size.height
        : geometry.control2.dy;
    /// 第二控制点到页面参考边的斜距。
    final double hmg = math.sqrt(
      geometry.control2.dx * geometry.control2.dx +
          control2ReferenceY * control2ReferenceY,
    );
    /// 旋转后阴影矩形的相对左边界。
    final double secondLeft =
        hmg > _maxLength ? -shadowWidth - hmg : -_maxLength;
    /// 旋转后阴影矩形的相对右边界。
    final double secondRight =
        hmg > _maxLength ? _maxLength - hmg : 0;
    _drawRotatedBand(
      canvas,
      pivot: geometry.control2,
      angle: secondAngle,
      rect: Rect.fromLTRB(
        secondLeft,
        geometry.isRightTopOrLeftBottom ? 0 : -shadowWidth,
        secondRight,
        geometry.isRightTopOrLeftBottom ? shadowWidth : 1,
      ),
      horizontalGradient: false,
      reverseGradient: !geometry.isRightTopOrLeftBottom,
      colors: _currentPageShadowColors,
    );
    canvas.restore();
  }

  /// 绘制页背靠近折叠边的有限阴影。
  void _drawFoldBackShadow(Canvas canvas) {
    /// 第一曲线起点到控制点中点的水平距离。
    final double firstWidth = ((geometry.start1.dx + geometry.control1.dx) /
                2 -
            geometry.control1.dx)
        .abs();
    /// 第二曲线起点到控制点中点的垂直距离。
    final double secondWidth = ((geometry.start2.dy + geometry.control2.dy) /
                2 -
            geometry.control2.dy)
        .abs();
    /// Android 页背阴影取两段距离中的较小值。
    final double width = math
        .min(firstWidth, secondWidth)
        .clamp(1, geometry.size.width)
        .toDouble();
    /// 页背阴影相对折痕起点的左边界。
    final double left = geometry.isRightTopOrLeftBottom ? -1 : -width - 1;
    /// 页背阴影相对折痕起点的右边界。
    final double right = geometry.isRightTopOrLeftBottom ? width + 1 : 1;
    /// 页背阴影与目标页阴影使用同一折叠方向角。
    final double angle = math.atan2(
      geometry.control1.dx - geometry.corner.dx,
      geometry.control2.dy - geometry.corner.dy,
    );
    canvas.save();
    canvas.clipPath(geometry.foldPath);
    canvas.clipPath(geometry.foldBackPath);
    _drawRotatedBand(
      canvas,
      pivot: geometry.start1,
      angle: angle,
      rect: Rect.fromLTRB(
        left,
        0,
        right,
        _maxLength,
      ),
      horizontalGradient: true,
      reverseGradient: !geometry.isRightTopOrLeftBottom,
      colors: _foldBackShadowColors,
    );
    canvas.restore();
  }

  /// 绘制一个绕指定点旋转、方向可反转的有限线性渐变带。
  void _drawRotatedBand(
    Canvas canvas, {
    required Offset pivot,
    required double angle,
    required Rect rect,
    required bool horizontalGradient,
    required bool reverseGradient,
    required List<Color> colors,
  }) {
    if (rect.isEmpty || !angle.isFinite) {
      return;
    }
    /// 渐变起始对齐方向。
    final Alignment begin = horizontalGradient
        ? (reverseGradient
            ? Alignment.centerRight
            : Alignment.centerLeft)
        : (reverseGradient
            ? Alignment.bottomCenter
            : Alignment.topCenter);
    /// 渐变结束对齐方向。
    final Alignment end = horizontalGradient
        ? (reverseGradient
            ? Alignment.centerLeft
            : Alignment.centerRight)
        : (reverseGradient
            ? Alignment.topCenter
            : Alignment.bottomCenter);
    /// 当前阴影带使用的有限线性渐变。
    final Paint paint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: begin,
        end: end,
        colors: colors,
      ).createShader(rect);
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(angle);
    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  /// 当前页面对角线长度，保证旋转后的有限阴影带覆盖可见折叠区域。
  double get _maxLength {
    return math.sqrt(
      geometry.size.width * geometry.size.width +
          geometry.size.height * geometry.size.height,
    );
  }

  /// 路径、配色或绘制层变化时刷新；动画帧不会触发正文重新分页。
  @override
  bool shouldRepaint(covariant _ReaderSimulationShadowPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.layer != layer;
  }
}
