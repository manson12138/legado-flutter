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

/// 保存跨平台阅读显示配置；翻页动画与 TTS 在后续阶段扩展，不进入 Widget 私有状态。
final class ReaderDisplayConfig {
  /// 创建第一批上下滚动阅读配置。
  const ReaderDisplayConfig({
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.paragraphSpacing = 12,
    this.horizontalPadding = 20,
    this.backgroundColorValue = 0xFFFFFBF2,
    this.textColorValue = 0xFF2B2925,
    this.useReplaceRules = true,
    this.keepScreenOn = true,
  });

  /// 正文字号，单位为逻辑像素。
  final double fontSize;

  /// 行高倍数。
  final double lineHeight;

  /// 正文块之间的段落间距，单位为逻辑像素。
  final double paragraphSpacing;

  /// 正文左右边距，单位为逻辑像素。
  final double horizontalPadding;

  /// ARGB 背景色整数，避免领域模型依赖 Flutter Color。
  final int backgroundColorValue;

  /// ARGB 正文字色整数，避免领域模型依赖 Flutter Color。
  final int textColorValue;

  /// 是否应用当前书籍和书源范围内的已启用替换规则。
  final bool useReplaceRules;

  /// 阅读期间是否请求平台保持屏幕常亮。
  final bool keepScreenOn;

  /// 复制显示配置并只覆盖用户本次修改的字段。
  ReaderDisplayConfig copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    int? backgroundColorValue,
    int? textColorValue,
    bool? useReplaceRules,
    bool? keepScreenOn,
  }) {
    return ReaderDisplayConfig(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      backgroundColorValue: backgroundColorValue ?? this.backgroundColorValue,
      textColorValue: textColorValue ?? this.textColorValue,
      useReplaceRules: useReplaceRules ?? this.useReplaceRules,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    );
  }
}
