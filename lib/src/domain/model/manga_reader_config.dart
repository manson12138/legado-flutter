/// 漫画阅读器支持的四种首版阅读方向。
enum MangaReadingMode {
  /// 横向单页，从左向右阅读。
  leftToRight(androidValue: 1, label: '从左到右'),

  /// 横向单页，从右向左阅读。
  rightToLeft(androidValue: 2, label: '从右到左'),

  /// 纵向单页，从上向下阅读。
  verticalPage(androidValue: 3, label: '从上到下'),

  /// 连续纵向条漫。
  webtoon(androidValue: 4, label: '连续条漫');

  /// 创建与 Android 配置值对齐的阅读模式。
  const MangaReadingMode({required this.androidValue, required this.label});

  /// Android `mangaScrollMode` 对应值。
  final int androidValue;

  /// 设置面板中的简短名称。
  final String label;

  /// 是否使用连续条漫布局。
  bool get isWebtoon => this == MangaReadingMode.webtoon;

  /// 是否使用纵向单页手势。
  bool get isVerticalPage => this == MangaReadingMode.verticalPage;

  /// 是否使用右到左的横向页面手势。
  bool get isRightToLeft => this == MangaReadingMode.rightToLeft;

  /// 从 Android 单书配置恢复模式；带间隙条漫 `5` 先归并为连续条漫。
  static MangaReadingMode fromAndroidValue(int? value) {
    return switch (value) {
      1 => MangaReadingMode.leftToRight,
      2 => MangaReadingMode.rightToLeft,
      3 => MangaReadingMode.verticalPage,
      4 || 5 => MangaReadingMode.webtoon,
      _ => MangaReadingMode.webtoon,
    };
  }
}

/// 当前路由内使用的漫画显示配置。
final class MangaReaderConfig {
  /// 创建不可变漫画显示配置。
  const MangaReaderConfig({
    this.readingMode = MangaReadingMode.webtoon,
    this.webtoonSidePadding = 0,
  });

  /// 当前阅读方向。
  final MangaReadingMode readingMode;

  /// 条漫左右逻辑像素留白。
  final double webtoonSidePadding;

  /// 从单书 Android 兼容字段建立安全配置。
  factory MangaReaderConfig.fromReadConfig({
    required int? mangaScrollMode,
    required int? webtoonSidePaddingDp,
  }) {
    /// 收敛后的条漫左右留白，避免异常配置挤掉正文。
    final double sidePadding = (webtoonSidePaddingDp ?? 0)
        .clamp(0, 48)
        .toDouble();
    return MangaReaderConfig(
      readingMode: MangaReadingMode.fromAndroidValue(mangaScrollMode),
      webtoonSidePadding: sidePadding,
    );
  }

  /// 复制配置并替换指定字段。
  MangaReaderConfig copyWith({
    MangaReadingMode? readingMode,
    double? webtoonSidePadding,
  }) {
    return MangaReaderConfig(
      readingMode: readingMode ?? this.readingMode,
      webtoonSidePadding: webtoonSidePadding ?? this.webtoonSidePadding,
    );
  }
}
