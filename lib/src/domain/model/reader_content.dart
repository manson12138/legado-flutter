/// 表示阅读器可稳定恢复的正文位置，不保存易受字体和屏幕宽度影响的滚动像素。
final class ReaderPositionAnchor {
  /// 创建由章节稳定地址、字符位置和附近正文组成的阅读锚点。
  const ReaderPositionAnchor({
    required this.chapterUrl,
    required this.chapterIndex,
    required this.characterOffset,
    required this.context,
  });

  /// 当前章节未经规范化的稳定地址。
  final String chapterUrl;

  /// 当前目录中的章节索引，章节地址失效时作为兼容回退。
  final int chapterIndex;

  /// 处理后正文中首个可见字符的位置。
  final int characterOffset;

  /// 锚点附近的短正文，用于正文变化后在相邻范围重新定位。
  final String context;
}

/// 表示一块可由惰性列表独立排版的正文，避免把超长章节交给单个 Text。
final class ReaderContentBlock {
  /// 创建带稳定字符区间的正文块。
  const ReaderContentBlock({
    required this.id,
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });

  /// 由章节地址和块序号生成的稳定列表键。
  final String id;

  /// 当前块需要显示的正文。
  final String text;

  /// 当前块在完整处理后正文中的起始字符位置。
  final int startOffset;

  /// 当前块在完整处理后正文中的结束字符位置，不包含该位置字符。
  final int endOffset;
}

/// 表示一章已经完成净化、替换和分块的正文结果。
final class ReaderChapterContent {
  /// 创建不可变章节正文。
  ReaderChapterContent({
    required this.chapterUrl,
    required this.title,
    required this.text,
    required List<ReaderContentBlock> blocks,
    required this.effectiveReplaceRuleCount,
    required this.fromCache,
  }) : blocks = List<ReaderContentBlock>.unmodifiable(blocks);

  /// 当前章节稳定地址。
  final String chapterUrl;

  /// 经过标题规则或书源结果确认的显示标题。
  final String title;

  /// 完整处理后正文，用于字符锚点、书签摘要和进度计算。
  final String text;

  /// 供惰性列表显示的有限大小正文块。
  final List<ReaderContentBlock> blocks;

  /// 本章实际改变正文的替换规则数量。
  final int effectiveReplaceRuleCount;

  /// 是否直接命中持久正文缓存。
  final bool fromCache;
}

/// 定义阅读正文的连续滚动或逐页呈现方式。
enum ReaderReadingMode {
  /// 上下连续滚动，并在章节边界自动衔接。
  continuous,

  /// 左右滑动或点击屏幕两侧逐页阅读。
  horizontalPaging,

  /// 上下滑动逐页阅读。
  verticalPaging,
}

/// 定义逐页阅读时的页面切换动画策略。
enum ReaderPageTurnStyle {
  /// Android 阅读器常用的覆盖翻页，目标页滑入并覆盖当前页。
  cover,

  /// 不使用动画，点击翻页时立即切换。
  none,

  /// 使用 Flutter PageView 默认滑动动画。
  slide,
}

/// 定义每章第一页标题的显示与水平排版方式。
enum ReaderTitleMode {
  /// 标题左对齐显示，对应 Android 标题模式默认值。
  left,

  /// 标题居中显示。
  center,

  /// 隐藏正文第一页中的章节标题，但页眉仍可显示章节名。
  hidden,
}

/// 定义阅读正文区域点击、长按或按键触发后的动作。
enum ReaderTapAction {
  /// 不执行任何动作，用于关闭某个触控区域。
  none,

  /// 打开上一页或上一章。
  previousPage,

  /// 打开下一页或下一章。
  nextPage,

  /// 切换顶部和底部阅读菜单。
  toggleMenu,

  /// 在当前阅读位置添加书签。
  addBookmark,
}

/// 定义阅读器对设备方向的请求策略。
enum ReaderOrientationMode {
  /// 跟随系统方向，不主动锁定。
  system,

  /// 锁定竖屏阅读。
  portrait,

  /// 锁定横屏阅读。
  landscape,
}

/// 保存跨平台阅读显示配置；翻页动画与 TTS 在后续阶段扩展，不进入 Widget 私有状态。
final class ReaderDisplayConfig {
  /// 创建默认覆盖翻页阅读配置。
  const ReaderDisplayConfig({
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.paragraphSpacing = 12,
    this.horizontalPadding = 20,
    this.verticalPadding = 20,
    this.letterSpacing = 0,
    this.fontWeightValue = 400,
    this.textItalic = false,
    this.backgroundColorValue = 0xFFFFFBF2,
    this.textColorValue = 0xFF2B2925,
    this.useReplaceRules = true,
    this.keepScreenOn = true,
    this.preDownloadCount = 10,
    this.readingMode = ReaderReadingMode.horizontalPaging,
    this.pageTurnStyle = ReaderPageTurnStyle.cover,
    this.showHeaderFooter = true,
    this.showMenuToolLabels = true,
    this.textShadow = false,
    this.textUnderline = false,
    this.titleMode = ReaderTitleMode.left,
    this.titleFontSizeOffset = 6,
    this.titleFontWeightValue = 600,
    this.titleTopSpacing = 8,
    this.titleBottomSpacing = 20,
    this.paragraphIndent = 2,
    this.textFullJustify = true,
    this.leftTapAction = ReaderTapAction.previousPage,
    this.centerTapAction = ReaderTapAction.toggleMenu,
    this.rightTapAction = ReaderTapAction.nextPage,
    this.longPressAction = ReaderTapAction.addBookmark,
    this.leftTapWidthRatio = 0.3,
    this.rightTapWidthRatio = 0.3,
    this.volumeKeyTurnPage = true,
    this.showClock = true,
    this.showBattery = true,
    this.useSystemBrightness = true,
    this.readerBrightness = 0.5,
    this.orientationMode = ReaderOrientationMode.system,
  });

  /// 正文字号，单位为逻辑像素。
  final double fontSize;

  /// 行高倍数。
  final double lineHeight;

  /// 正文块之间的段落间距，单位为逻辑像素。
  final double paragraphSpacing;

  /// 正文左右边距，单位为逻辑像素。
  final double horizontalPadding;

  /// 正文上下边距，单位为逻辑像素，对应 Android PaddingConfig 的纵向留白子集。
  final double verticalPadding;

  /// 正文字距，单位为逻辑像素，对应 Android TextTitleSheet 的字距子集。
  final double letterSpacing;

  /// 正文字重数值，使用 300、400、500、700 等跨平台稳定值。
  final int fontWeightValue;

  /// 正文是否使用斜体，对应 Android TextTitleSheet 的斜体开关子集。
  final bool textItalic;

  /// ARGB 背景色整数，避免领域模型依赖 Flutter Color。
  final int backgroundColorValue;

  /// ARGB 正文字色整数，避免领域模型依赖 Flutter Color。
  final int textColorValue;

  /// 是否应用当前书籍和书源范围内的已启用替换规则。
  final bool useReplaceRules;

  /// 阅读期间是否请求平台保持屏幕常亮。
  final bool keepScreenOn;

  /// 当前章节成功后允许低优先级预下载的章节数量。
  final int preDownloadCount;

  /// 当前正文连续滚动或逐页呈现方式。
  final ReaderReadingMode readingMode;

  /// 当前逐页阅读点击翻页的动画策略。
  final ReaderPageTurnStyle pageTurnStyle;

  /// 是否显示阅读页眉页脚信息。
  final bool showHeaderFooter;

  /// 阅读菜单底部工具按钮是否显示文字标签。
  final bool showMenuToolLabels;

  /// 正文是否显示轻量文字阴影。
  final bool textShadow;

  /// 正文是否显示下划线。
  final bool textUnderline;

  /// 每章第一页标题的显示与水平排版方式。
  final ReaderTitleMode titleMode;

  /// 标题字号相对正文字号增加的逻辑像素值。
  final double titleFontSizeOffset;

  /// 标题字重数值，独立于正文字重。
  final int titleFontWeightValue;

  /// 标题顶部留白，单位为逻辑像素。
  final double titleTopSpacing;

  /// 标题与正文之间的底部留白，单位为逻辑像素。
  final double titleBottomSpacing;

  /// 每个正文段落首行使用的全角空格数量。
  final int paragraphIndent;

  /// 是否对非段落末行分配剩余宽度以实现两端对齐。
  final bool textFullJustify;

  /// 正文左侧点击区域执行的动作。
  final ReaderTapAction leftTapAction;

  /// 正文中间点击区域执行的动作。
  final ReaderTapAction centerTapAction;

  /// 正文右侧点击区域执行的动作。
  final ReaderTapAction rightTapAction;

  /// 正文长按时执行的动作；当前先提供菜单、翻页和书签等无选择态动作。
  final ReaderTapAction longPressAction;

  /// 左侧点击区域占阅读宽度的比例。
  final double leftTapWidthRatio;

  /// 右侧点击区域占阅读宽度的比例。
  final double rightTapWidthRatio;

  /// 是否把系统音量键映射为上一页和下一页。
  final bool volumeKeyTurnPage;

  /// 页眉页脚是否显示当前时间。
  final bool showClock;

  /// 页眉页脚是否显示平台电量。
  final bool showBattery;

  /// 阅读器是否跟随系统亮度；关闭后使用 readerBrightness。
  final bool useSystemBrightness;

  /// 阅读器自定义亮度，取值范围为 0.05～1.0。
  final double readerBrightness;

  /// 阅读器方向锁定策略。
  final ReaderOrientationMode orientationMode;

  /// 复制显示配置并只覆盖用户本次修改的字段。
  ReaderDisplayConfig copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    double? verticalPadding,
    double? letterSpacing,
    int? fontWeightValue,
    bool? textItalic,
    int? backgroundColorValue,
    int? textColorValue,
    bool? useReplaceRules,
    bool? keepScreenOn,
    int? preDownloadCount,
    ReaderReadingMode? readingMode,
    ReaderPageTurnStyle? pageTurnStyle,
    bool? showHeaderFooter,
    bool? showMenuToolLabels,
    bool? textShadow,
    bool? textUnderline,
    ReaderTitleMode? titleMode,
    double? titleFontSizeOffset,
    int? titleFontWeightValue,
    double? titleTopSpacing,
    double? titleBottomSpacing,
    int? paragraphIndent,
    bool? textFullJustify,
    ReaderTapAction? leftTapAction,
    ReaderTapAction? centerTapAction,
    ReaderTapAction? rightTapAction,
    ReaderTapAction? longPressAction,
    double? leftTapWidthRatio,
    double? rightTapWidthRatio,
    bool? volumeKeyTurnPage,
    bool? showClock,
    bool? showBattery,
    bool? useSystemBrightness,
    double? readerBrightness,
    ReaderOrientationMode? orientationMode,
  }) {
    return ReaderDisplayConfig(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      verticalPadding: verticalPadding ?? this.verticalPadding,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      fontWeightValue: fontWeightValue ?? this.fontWeightValue,
      textItalic: textItalic ?? this.textItalic,
      backgroundColorValue: backgroundColorValue ?? this.backgroundColorValue,
      textColorValue: textColorValue ?? this.textColorValue,
      useReplaceRules: useReplaceRules ?? this.useReplaceRules,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      preDownloadCount: preDownloadCount ?? this.preDownloadCount,
      readingMode: readingMode ?? this.readingMode,
      pageTurnStyle: pageTurnStyle ?? this.pageTurnStyle,
      showHeaderFooter: showHeaderFooter ?? this.showHeaderFooter,
      showMenuToolLabels: showMenuToolLabels ?? this.showMenuToolLabels,
      textShadow: textShadow ?? this.textShadow,
      textUnderline: textUnderline ?? this.textUnderline,
      titleMode: titleMode ?? this.titleMode,
      titleFontSizeOffset: titleFontSizeOffset ?? this.titleFontSizeOffset,
      titleFontWeightValue: titleFontWeightValue ?? this.titleFontWeightValue,
      titleTopSpacing: titleTopSpacing ?? this.titleTopSpacing,
      titleBottomSpacing: titleBottomSpacing ?? this.titleBottomSpacing,
      paragraphIndent: paragraphIndent ?? this.paragraphIndent,
      textFullJustify: textFullJustify ?? this.textFullJustify,
      leftTapAction: leftTapAction ?? this.leftTapAction,
      centerTapAction: centerTapAction ?? this.centerTapAction,
      rightTapAction: rightTapAction ?? this.rightTapAction,
      longPressAction: longPressAction ?? this.longPressAction,
      leftTapWidthRatio: leftTapWidthRatio ?? this.leftTapWidthRatio,
      rightTapWidthRatio: rightTapWidthRatio ?? this.rightTapWidthRatio,
      volumeKeyTurnPage: volumeKeyTurnPage ?? this.volumeKeyTurnPage,
      showClock: showClock ?? this.showClock,
      showBattery: showBattery ?? this.showBattery,
      useSystemBrightness: useSystemBrightness ?? this.useSystemBrightness,
      readerBrightness: readerBrightness ?? this.readerBrightness,
      orientationMode: orientationMode ?? this.orientationMode,
    );
  }
}
