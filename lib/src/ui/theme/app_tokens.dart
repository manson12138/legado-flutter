import 'package:flutter/material.dart';

/// 定义应用品牌色和基础语义色，业务页面不得直接散落颜色常量。
abstract final class ColorToken {
  /// 应用主品牌种子色，使用更低存在感的灰绿色，支撑简约界面的少量强调。
  static const Color seed = Color(0xFF4F6656);

  /// 亮色模式背景，降低原先暖纸色的色彩存在感，让页面更接近干净浅灰。
  static const Color lightPaper = Color(0xFFFAFAF7);

  /// 深色模式背景，保持柔和黑灰，避免纯黑造成正文和控件对比过硬。
  static const Color darkPaper = Color(0xFF131512);

  /// 生成亮色主题的 Material 3 颜色方案。
  static ColorScheme lightScheme() {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: lightPaper,
    );
  }

  /// 生成深色主题的 Material 3 颜色方案。
  static ColorScheme darkScheme() {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: darkPaper,
    );
  }
}

/// 定义应用排版基线，普通 UI 跟随系统文字缩放。
abstract final class TypographyToken {
  /// 大屏和强调区域使用的展示标题字号，较早期视觉约缩小四分之一。
  static const double headlineLargeSize = 24;

  /// 页面主标题使用的字号，用于 AppBar 和详情标题的紧凑基线。
  static const double titleLargeSize = 18;

  /// 页面主要正文使用的字号，避免列表和表单显得过大。
  static const double bodyLargeSize = 14;

  /// 页面辅助正文使用的字号，用于来源、状态和说明文本。
  static const double bodyMediumSize = 12.5;

  /// 小标签和元信息使用的字号，控制 Chip、Badge 和列表辅助信息的密度。
  static const double labelSmallSize = 11.5;

  /// 根据 Material 3 默认排版生成项目排版规则。
  static TextTheme textTheme(TextTheme base) {
    return base.copyWith(
      headlineLarge: base.headlineLarge?.copyWith(
        fontSize: headlineLargeSize,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: titleLargeSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: base.titleMedium?.copyWith(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0),
      titleSmall: base.titleSmall?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: bodyLargeSize),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: bodyMediumSize),
      labelLarge: base.labelLarge?.copyWith(fontSize: 13, letterSpacing: 0),
      labelMedium: base.labelMedium?.copyWith(fontSize: 12, letterSpacing: 0),
      labelSmall: base.labelSmall?.copyWith(fontSize: labelSmallSize, letterSpacing: 0),
    );
  }
}

/// 定义以 4 logical pixels 为节奏的统一间距。
abstract final class SpacingToken {
  /// 最小紧凑间距，服务图标和元信息之间的轻量分隔。
  static const double xSmall = 3;

  /// 小间距，较早期 8dp 基线收缩，减少列表和表单的空白。
  static const double small = 6;

  /// 中小间距，用于卡片内部较短边距和相邻控件间距。
  static const double mediumSmall = 8;

  /// 页面默认间距，作为紧凑版页面左右留白。
  static const double medium = 12;

  /// 中大间距，用于重要区块但避免形成大面积留白。
  static const double mediumLarge = 14;

  /// 区块间距，较早期视觉约缩小三分之一。
  static const double large = 16;

  /// 页面大区块间距，只用于空态和较强分隔的区域。
  static const double xLarge = 22;
}

/// 定义组件圆角，保证卡片、按钮和弹层具有一致轮廓。
abstract final class RadiusToken {
  /// 小型控件圆角，简约风格下保持轻微圆角。
  static const double small = 6;

  /// 卡片和输入框默认圆角，避免控件显得过厚重。
  static const double medium = 8;

  /// 大型容器圆角，用于弹层和强调容器的克制圆角。
  static const double large = 12;

  /// 底部面板顶部圆角，缩小后让面板更像工具层而非大卡片。
  static const double sheet = 16;

  /// 搜索框和胶囊按钮使用的完整圆角。
  static const double pill = 999;
}

/// 定义响应式断点、内容宽度和触控尺寸，页面不得自行散落设备判断。
abstract final class LayoutToken {
  /// 小于该宽度时使用手机紧凑布局。
  static const double compactBreakpoint = 600;

  /// 达到该宽度时使用带完整标签的宽屏导航栏。
  static const double expandedBreakpoint = 840;

  /// 普通信息页面的最大正文宽度，让宽屏下内容更集中。
  static const double contentMaxWidth = 980;

  /// 阅读正文在平板和桌面上的最大排版宽度。
  static const double readerMaxWidth = 720;

  /// 宽屏辅助面板的建议宽度，给双栏页面保留更多主内容区域。
  static const double sidePanelWidth = 320;

  /// 主要交互控件的最小触控尺寸。
  static const double minimumTouchTarget = 44;

  /// 标准小说封面的宽高比。
  static const double bookCoverAspectRatio = 2 / 3;
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
  /// 阅读正文初始字号，作为偏小阅读视觉的默认值，后续由用户设置覆盖。
  static const double defaultFontSize = 15;

  /// 阅读正文初始行高倍数，随字号收紧但保留中文段落可读性。
  static const double defaultLineHeight = 1.55;

  /// 阅读正文初始水平边距，减少手机阅读页左右空白。
  static const double defaultHorizontalPadding = 14;

  /// 阅读器暖纸主题的默认背景色。
  static const Color paperBackground = Color(0xFFF4ECD8);

  /// 阅读器暖纸主题的默认正文色。
  static const Color paperForeground = Color(0xFF2F2B24);
}
