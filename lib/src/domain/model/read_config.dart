/// 保存单本书的阅读行为配置，对应 Android `Book.ReadConfig`。
///
/// 该模型只表达跨平台业务配置，不依赖数据库或 Flutter UI；数据库使用 JSON 文本保存。
final class ReadConfig {
  /// 创建不可变的单书阅读配置。
  const ReadConfig({
    this.reverseToc = false,
    this.pageAnim,
    this.reSegment = false,
    this.imageStyle,
    this.useReplaceRule,
    this.delTag = 0,
    this.ttsEngine,
    this.splitLongChapter = true,
    this.readSimulating = false,
    this.startDate,
    this.startChapter,
    this.dailyChapters = 3,
    this.mangaColorFilter,
    this.mangaScrollMode,
    this.webtoonSidePaddingDp,
    this.mangaBackground,
    this.fixedType = false,
    this.translationMode = false,
  });

  /// 目录是否反转显示，对应 Android `reverseToc`。
  final bool reverseToc;

  /// 单书覆盖的翻页动画编号；`null` 表示继续使用全局配置。
  final int? pageAnim;

  /// 是否对长正文重新分段，对应 Android `reSegment`。
  final bool reSegment;

  /// 图片阅读显示样式；`null` 表示使用阅读器默认值。
  final String? imageStyle;

  /// 是否使用净化替换规则；`null` 表示按书籍类型和全局默认值决定。
  final bool? useReplaceRule;

  /// 需要移除的 HTML 标签位掩码，对应 Android `delTag`。
  final int delTag;

  /// 单书指定的 TTS 引擎标识；`null` 表示使用全局引擎。
  final String? ttsEngine;

  /// 是否拆分过长章节，对应 Android `splitLongChapter`。
  final bool splitLongChapter;

  /// 是否启用模拟阅读进度。
  final bool readSimulating;

  /// 模拟阅读开始日期，沿用 Android 的 ISO-8601 字符串语义。
  final String? startDate;

  /// 模拟阅读起始章节；`null` 表示没有单独设置。
  final int? startChapter;

  /// 模拟阅读每日推进的章节数量。
  final int dailyChapters;

  /// 漫画颜色滤镜配置文本；具体格式由后续阅读器阶段解释。
  final String? mangaColorFilter;

  /// 漫画滚动模式编号；`null` 表示使用全局配置。
  final int? mangaScrollMode;

  /// Webtoon 左右边距，单位为逻辑像素 dp。
  final int? webtoonSidePaddingDp;

  /// 漫画背景配置文本；具体格式由后续阅读器阶段解释。
  final String? mangaBackground;

  /// 是否固定书籍类型，避免换源更新时覆盖用户选择。
  final bool fixedType;

  /// 是否启用翻译阅读模式。
  final bool translationMode;

  /// 将配置转换为可 JSON 编码的稳定字段集合。
  Map<String, Object?> toJson() {
    /// 与 Android `Book.ReadConfig` 字段同名的序列化结果。
    final Map<String, Object?> json = <String, Object?>{
      'reverseToc': reverseToc,
      'pageAnim': pageAnim,
      'reSegment': reSegment,
      'imageStyle': imageStyle,
      'useReplaceRule': useReplaceRule,
      'delTag': delTag,
      'ttsEngine': ttsEngine,
      'splitLongChapter': splitLongChapter,
      'readSimulating': readSimulating,
      'startDate': startDate,
      'startChapter': startChapter,
      'dailyChapters': dailyChapters,
      'mangaColorFilter': mangaColorFilter,
      'mangaScrollMode': mangaScrollMode,
      'webtoonSidePaddingDp': webtoonSidePaddingDp,
      'mangaBackground': mangaBackground,
      'fixedType': fixedType,
      'translationMode': translationMode,
    };
    return json;
  }

  /// 从受控 JSON 对象恢复配置；错误或缺失字段使用 Android 当前默认值。
  factory ReadConfig.fromJson(Map<String, Object?> json) {
    return ReadConfig(
      reverseToc: json['reverseToc'] is bool ? json['reverseToc'] as bool : false,
      pageAnim: json['pageAnim'] is num ? (json['pageAnim'] as num).toInt() : null,
      reSegment: json['reSegment'] is bool ? json['reSegment'] as bool : false,
      imageStyle: json['imageStyle'] is String ? json['imageStyle'] as String : null,
      useReplaceRule: json['useReplaceRule'] is bool
          ? json['useReplaceRule'] as bool
          : null,
      delTag: json['delTag'] is num ? (json['delTag'] as num).toInt() : 0,
      ttsEngine: json['ttsEngine'] is String ? json['ttsEngine'] as String : null,
      splitLongChapter: json['splitLongChapter'] is bool
          ? json['splitLongChapter'] as bool
          : true,
      readSimulating: json['readSimulating'] is bool
          ? json['readSimulating'] as bool
          : false,
      startDate: json['startDate'] is String ? json['startDate'] as String : null,
      startChapter: json['startChapter'] is num
          ? (json['startChapter'] as num).toInt()
          : null,
      dailyChapters: json['dailyChapters'] is num
          ? (json['dailyChapters'] as num).toInt()
          : 3,
      mangaColorFilter: json['mangaColorFilter'] is String
          ? json['mangaColorFilter'] as String
          : null,
      mangaScrollMode: json['mangaScrollMode'] is num
          ? (json['mangaScrollMode'] as num).toInt()
          : null,
      webtoonSidePaddingDp: json['webtoonSidePaddingDp'] is num
          ? (json['webtoonSidePaddingDp'] as num).toInt()
          : null,
      mangaBackground: json['mangaBackground'] is String
          ? json['mangaBackground'] as String
          : null,
      fixedType: json['fixedType'] is bool ? json['fixedType'] as bool : false,
      translationMode: json['translationMode'] is bool
          ? json['translationMode'] as bool
          : false,
    );
  }
}
