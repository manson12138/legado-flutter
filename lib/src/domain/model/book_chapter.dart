/// 表示一本书中的持久化章节，对应 Android `data.entities.BookChapter`。
final class BookChapter {
  /// 创建不可变章节。
  const BookChapter({
    required this.url,
    required this.title,
    required this.bookUrl,
    required this.index,
    this.isVolume = false,
    this.baseUrl = '',
    this.isVip = false,
    this.isPay = false,
    this.resourceUrl,
    this.tag,
    this.wordCount,
    this.start,
    this.end,
    this.startFragmentId,
    this.endFragmentId,
    this.variable,
    this.reviewImg,
  });

  /// 章节原始地址，与 `bookUrl` 共同组成主键；不做 URL 规范化。
  final String url;
  /// 章节标题。
  final String title;
  /// 是否为卷标题而非可阅读章节。
  final bool isVolume;
  /// 拼接相对章节 URL 使用的基准地址。
  final String baseUrl;
  /// 所属书籍主键，外键指向 `books.bookUrl`。
  final String bookUrl;
  /// 章节从零开始的稳定顺序，同一本书内唯一。
  final int index;
  /// 是否为 VIP 章节。
  final bool isVip;
  /// 是否已购买该章节。
  final bool isPay;
  /// 音频章节的真实资源 URL。
  final String? resourceUrl;
  /// 更新时间或书源提供的其他章节附加信息。
  final String? tag;
  /// 章节字数显示文本。
  final String? wordCount;
  /// 本地文件中章节起始字节或字符偏移；`null` 表示不适用。
  final int? start;
  /// 本地文件中章节结束字节或字符偏移；`null` 表示不适用。
  final int? end;
  /// EPUB 当前章节起始 fragmentId。
  final String? startFragmentId;
  /// EPUB 下一章节起始 fragmentId。
  final String? endFragmentId;
  /// 规则解析期间持久化的章节变量 JSON 文本。
  final String? variable;
  /// 段评图标地址。
  final String? reviewImg;
}
