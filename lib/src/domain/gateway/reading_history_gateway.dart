import '../model/book.dart';
import '../model/book_chapter.dart';

/// 管理与书架成员资格独立的阅读历史书籍和目录快照。
abstract interface class ReadingHistoryGateway {
  /// 按最近阅读时间倒序观察全部历史书籍。
  Stream<List<Book>> watchHistory();

  /// 按稳定书籍 URL 读取一条历史书籍快照。
  Future<Book?> getHistoryBook(String bookUrl);

  /// 按章节索引读取一条历史目录快照。
  Future<List<BookChapter>> getHistoryChapters(String bookUrl);

  /// 原子保存书籍与完整目录快照，重复阅读同一本书时覆盖旧快照。
  Future<void> recordHistory(Book book, List<BookChapter> chapters);

  /// 更新历史书籍的阅读章节、字符位置和最后阅读时间。
  Future<bool> updateHistoryProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
    required int readTime,
    required String? chapterTitle,
  });
}
