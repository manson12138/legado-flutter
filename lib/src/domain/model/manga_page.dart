/// 漫画章节中的一张稳定图片页，对应 Android `MangaPage`。
final class MangaPage {
  /// 创建已完成地址校验的不可变漫画页。
  const MangaPage({
    required this.chapterUrl,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitle,
    required this.imageIndex,
    required this.imageCount,
    required this.imageUri,
    required this.requestUrl,
    required this.referer,
    required this.altText,
  });

  /// 所属章节的稳定地址，用于跨重建识别页面身份。
  final String chapterUrl;

  /// 所属章节从零开始的目录索引。
  final int chapterIndex;

  /// 当前目录中的章节总数。
  final int chapterCount;

  /// 所属章节标题。
  final String chapterTitle;

  /// 图片在当前章节中从零开始的位置。
  final int imageIndex;

  /// 当前章节的有效图片总数。
  final int imageCount;

  /// 已解析为绝对 HTTP(S) 地址的图片资源。
  final Uri imageUri;

  /// 交给统一书源 URL 解析器的绝对请求规则，可保留图片地址携带的 Header 选项。
  final String requestUrl;

  /// 图片请求防盗链可使用的章节来源地址；空字符串表示没有安全来源地址。
  final String referer;

  /// 图片加载失败时可展示的简短替代文本。
  final String altText;

  /// 由章节地址、图片地址和章节内位置共同组成的身份，不把瞬时下标作为唯一依据。
  ///
  /// 章节内位置用于区分正文中不相邻地重复出现的同一图片资源。
  String get stableKey => '$chapterUrl\u001F${imageUri.toString()}\u001F$imageIndex';
}
