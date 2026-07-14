import 'package:flutter/material.dart';

/// 定义应用品牌色和基础语义色，业务页面不得直接散落颜色常量。
abstract final class ColorToken {
  /// 生成亮色主题的 Material 3 颜色方案。
  static ColorScheme lightScheme() {
    return ColorScheme.fromSeed(
      seedColor: const Color(0xFF496645),
      brightness: Brightness.light,
    );
  }

  /// 生成深色主题的 Material 3 颜色方案。
  static ColorScheme darkScheme() {
    return ColorScheme.fromSeed(
      seedColor: const Color(0xFF9DCF96),
      brightness: Brightness.dark,
    );
  }
}

/// 定义应用排版基线，普通 UI 跟随系统文字缩放。
abstract final class TypographyToken {
  /// 页面主标题使用的字号。
  static const double titleLargeSize = 22;

  /// 页面主要正文使用的字号。
  static const double bodyLargeSize = 16;

  /// 页面辅助正文使用的字号。
  static const double bodyMediumSize = 14;

  /// 根据 Material 3 默认排版生成项目排版规则。
  static TextTheme textTheme(TextTheme base) {
    return base.copyWith(
      titleLarge: base.titleLarge?.copyWith(
        fontSize: titleLargeSize,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: bodyLargeSize),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: bodyMediumSize),
    );
  }
}

/// 定义以 4 logical pixels 为节奏的统一间距。
abstract final class SpacingToken {
  /// 最小紧凑间距。
  static const double xSmall = 4;

  /// 小间距。
  static const double small = 8;

  /// 中小间距。
  static const double mediumSmall = 12;

  /// 页面默认间距。
  static const double medium = 16;

  /// 中大间距。
  static const double mediumLarge = 20;

  /// 区块间距。
  static const double large = 24;

  /// 页面大区块间距。
  static const double xLarge = 32;
}

/// 定义组件圆角，保证卡片、按钮和弹层具有一致轮廓。
abstract final class RadiusToken {
  /// 小型控件圆角。
  static const double small = 8;

  /// 卡片和输入框默认圆角。
  static const double medium = 12;

  /// 大型容器圆角。
  static const double large = 20;

  /// 底部面板顶部圆角。
  static const double sheet = 28;
}

/// 定义界面层级使用的阴影和 Material 高度。
abstract final class ElevationToken {
  /// 无浮起效果的平面高度。
  static const double none = 0;

  /// 卡片的轻量高度。
  static const double card = 1;

  /// 浮层的标准高度。
  static const double overlay = 6;

  /// 卡片需要显式阴影时使用的统一阴影。
  static const List<BoxShadow> cardShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A000000),
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];
}

/// 定义交互动画时长，避免组件各自使用魔法数字。
abstract final class DurationToken {
  /// 轻量反馈动画时长。
  static const Duration short = Duration(milliseconds: 150);

  /// 常规页面状态切换动画时长。
  static const Duration medium = Duration(milliseconds: 250);

  /// 强调型进入或退出动画时长。
  static const Duration long = Duration(milliseconds: 400);
}

/// 定义交互动画曲线，和 [DurationToken] 共同组成动画 Token。
abstract final class AnimationToken {
  /// 常规状态变化使用的平滑曲线。
  static const Curve standard = Curves.easeInOutCubic;

  /// 元素进入页面时使用的减速曲线。
  static const Curve enter = Curves.easeOutCubic;
}

/// 定义阅读器未来会共享的基础排版 Token，不在 M1 实现阅读业务。
abstract final class ReaderToken {
  /// 阅读正文初始字号，后续由用户设置覆盖。
  static const double defaultFontSize = 18;

  /// 阅读正文初始行高倍数。
  static const double defaultLineHeight = 1.7;

  /// 阅读正文初始水平边距。
  static const double defaultHorizontalPadding = 20;
}
