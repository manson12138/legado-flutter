import '../model/book_chapter.dart';

/// 定义目录读取和整体保存边界。
abstract interface class ChapterGateway {
  /// 按章节索引升序读取完整目录。
  Future<List<BookChapter>> getChapterList(String bookUrl);

  /// 观察一本书的完整目录。
  Stream<List<BookChapter>> watchChapterList(String bookUrl);

  /// 在事务中用 [chapters] 整体替换指定书籍的目录。
  Future<void> replaceChapterList(
    String bookUrl,
    List<BookChapter> chapters,
  );
}
