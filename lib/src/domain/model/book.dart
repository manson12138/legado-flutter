import 'read_config.dart';

/// 表示书架中的持久化书籍，对应 Android `data.entities.Book`。
///
/// URL 不做规范化，避免改变 Android 以原始详情页 URL 作为主键的唯一性语义。
final class Book {
  /// 创建不可变书籍；所有时间字段均为 Unix Epoch 毫秒。
  const Book({
    required this.bookUrl,
    this.tocUrl = '',
    this.origin = 'loc_book',
    this.originName = '',
    this.name = '',
    this.author = '',
    this.kind,
    this.customTag,
    this.coverUrl,
    this.customCoverUrl,
    this.intro,
    this.customIntro,
    this.remark,
    this.charset,
    this.type = 0,
    this.group = 0,
    this.latestChapterTitle,
    this.latestChapterTime = 0,
    this.lastCheckTime = 0,
    this.lastCheckCount = 0,
    this.totalChapterNum = 0,
    this.durChapterTitle,
    this.durChapterIndex = 0,
    this.durChapterPos = 0,
    this.durChapterTime = 0,
    this.wordCount,
    this.canUpdate = true,
    this.order = 0,
    this.originOrder = 0,
    this.variable,
    this.readConfig,
    this.syncTime = 0,
  });

  /// 详情页 URL 或本地稳定内容地址，也是 `books` 表主键；本地书不保存临时绝对路径。
  final String bookUrl;
  /// 目录页 URL；空字符串表示尚未解析到独立目录地址。
  final String tocUrl;
  /// 书源 URL；本地书默认使用 Android 兼容标识 `loc_book`。
  final String origin;
  /// 书源名称，或本地书文件名。
  final String originName;
  /// 书名。
  final String name;
  /// 作者名。
  final String author;
  /// 书源返回的分类文本；`null` 与空字符串保持不同含义。
  final String? kind;
  /// 用户自定义分类文本。
  final String? customTag;
  /// 书源返回的封面 URL。
  final String? coverUrl;
  /// 用户覆盖的封面 URL。
  final String? customCoverUrl;
  /// 书源返回的简介。
  final String? intro;
  /// 用户覆盖的简介。
  final String? customIntro;
  /// 用户备注。
  final String? remark;
  /// 本地书自定义字符集名称。
  final String? charset;
  /// Android `BookType` 位掩码；数值语义在规则阶段继续对齐。
  final int type;
  /// 用户分组位掩码；0 表示没有用户分组。
  final int group;
  /// 最新章节标题。
  final String? latestChapterTitle;
  /// 最新章节标题更新时间，Unix Epoch 毫秒；0 表示未知。
  final int latestChapterTime;
  /// 最近检查书籍信息时间，Unix Epoch 毫秒；0 表示未检查。
  final int lastCheckTime;
  /// 最近检查发现的新章节数量。
  final int lastCheckCount;
  /// 当前已知目录章节总数。
  final int totalChapterNum;
  /// 当前阅读章节标题。
  final String? durChapterTitle;
  /// 当前阅读章节的从零开始索引。
  final int durChapterIndex;
  /// 当前章节首个可见字符的位置。
  final int durChapterPos;
  /// 最近打开正文的时间，Unix Epoch 毫秒；0 表示从未阅读。
  final int durChapterTime;
  /// Android 兼容字数显示文本，不强制转换为整数。
  final String? wordCount;
  /// 刷新书架时是否允许更新书籍信息。
  final bool canUpdate;
  /// 用户手动排序值。
  final int order;
  /// 当前书源的排序值。
  final int originOrder;
  /// 书源规则使用的自定义变量 JSON 文本。
  final String? variable;
  /// 单书阅读配置；`null` 表示从未保存单书覆盖配置。
  final ReadConfig? readConfig;
  /// 阅读进度同步时间，Unix Epoch 毫秒；0 表示未同步。
  final int syncTime;

  /// 用新的阅读位置构造书籍副本，不改变其他书籍事实。
  Book copyWithProgress({
    required int chapterIndex,
    required int chapterPos,
    required int readTime,
    String? chapterTitle,
  }) {
    return Book(
      bookUrl: bookUrl,
      tocUrl: tocUrl,
      origin: origin,
      originName: originName,
      name: name,
      author: author,
      kind: kind,
      customTag: customTag,
      coverUrl: coverUrl,
      customCoverUrl: customCoverUrl,
      intro: intro,
      customIntro: customIntro,
      remark: remark,
      charset: charset,
      type: type,
      group: group,
      latestChapterTitle: latestChapterTitle,
      latestChapterTime: latestChapterTime,
      lastCheckTime: lastCheckTime,
      lastCheckCount: lastCheckCount,
      totalChapterNum: totalChapterNum,
      durChapterTitle: chapterTitle,
      durChapterIndex: chapterIndex,
      durChapterPos: chapterPos,
      durChapterTime: readTime,
      wordCount: wordCount,
      canUpdate: canUpdate,
      order: order,
      originOrder: originOrder,
      variable: variable,
      readConfig: readConfig,
      syncTime: syncTime,
    );
  }
}
