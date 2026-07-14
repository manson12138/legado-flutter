/// 表示阅读书签，对应 Android `data.entities.Bookmark`。
final class Bookmark {
  /// 创建不可变书签。
  const Bookmark({
    required this.time,
    required this.bookName,
    required this.bookAuthor,
    required this.chapterIndex,
    required this.chapterPos,
    required this.chapterName,
    required this.bookText,
    required this.content,
  });

  /// 创建书签时间，Unix Epoch 毫秒，同时作为主键。
  final int time;
  /// 书名；Android 书签按书名和作者关联，不使用 `bookUrl`。
  final String bookName;
  /// 作者名。
  final String bookAuthor;
  /// 章节从零开始的索引。
  final int chapterIndex;
  /// 章节内字符位置。
  final int chapterPos;
  /// 章节标题。
  final String chapterName;
  /// 创建书签时保存的附近正文摘要。
  final String bookText;
  /// 用户编辑的书签内容。
  final String content;
}
