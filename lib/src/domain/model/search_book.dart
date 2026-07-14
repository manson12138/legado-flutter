import 'book.dart';

/// 表示一次搜索得到并暂存的候选书，对应 Android `data.entities.SearchBook`。
///
/// 搜索结果不是书架书，不能与 [Book] 合并；加入书架时必须通过 [toBook] 明确转换。
final class SearchBook {
  /// 创建不可变搜索结果；所有时间字段均为 Unix Epoch 毫秒。
  const SearchBook({
    required this.bookUrl,
    required this.origin,
    required this.originName,
    required this.name,
    required this.author,
    this.type = 0,
    this.kind,
    this.coverUrl,
    this.intro,
    this.wordCount,
    this.latestChapterTitle,
    this.tocUrl = '',
    this.time = 0,
    this.variable,
    this.originOrder = 0,
    this.chapterWordCountText,
    this.chapterWordCount = -1,
    this.respondTime = -1,
  });

  /// 详情页 URL，也是搜索缓存主键。
  final String bookUrl;
  /// 产生结果的书源 URL，外键指向 `book_sources.bookSourceUrl`。
  final String origin;
  /// 产生结果的书源名称。
  final String originName;
  /// Android `BookType` 位掩码。
  final int type;
  /// 书名。
  final String name;
  /// 作者名。
  final String author;
  /// 分类文本。
  final String? kind;
  /// 封面 URL。
  final String? coverUrl;
  /// 简介文本。
  final String? intro;
  /// 字数显示文本。
  final String? wordCount;
  /// 最新章节标题。
  final String? latestChapterTitle;
  /// 目录页 URL；空字符串表示尚未解析。
  final String tocUrl;
  /// 搜索结果写入时间，Unix Epoch 毫秒。
  final int time;
  /// 规则解析变量 JSON 文本。
  final String? variable;
  /// 书源排序值，用于结果换源排序。
  final int originOrder;
  /// 章节字数的原始显示文本。
  final String? chapterWordCountText;
  /// 解析后的章节字数；-1 表示未知。
  final int chapterWordCount;
  /// 搜索响应耗时，单位毫秒；-1 表示未记录。
  final int respondTime;

  /// 将搜索结果转换为新的书架书，不携带搜索缓存专属统计字段。
  Book toBook({required int createdAt}) {
    return Book(
      bookUrl: bookUrl,
      tocUrl: tocUrl,
      origin: origin,
      originName: originName,
      name: name,
      author: author,
      kind: kind,
      coverUrl: coverUrl,
      intro: intro,
      type: type,
      latestChapterTitle: latestChapterTitle,
      latestChapterTime: createdAt,
      lastCheckTime: createdAt,
      durChapterTime: createdAt,
      wordCount: wordCount,
      originOrder: originOrder,
      variable: variable,
    );
  }
}
