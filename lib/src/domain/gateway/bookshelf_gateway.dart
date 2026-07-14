import '../model/book.dart';
import '../model/book_chapter.dart';

/// 定义书架书持久化边界，协调书籍和目录的关键事务。
abstract interface class BookshelfGateway {
  /// 观察全部书架书，按最近阅读时间倒序返回。
  Stream<List<Book>> watchBookshelf();

  /// 按未经规范化的书籍 URL 查询书架书。
  Future<Book?> getBook(String bookUrl);

  /// 在一个事务中写入书籍及可选完整目录。
  Future<void> addBook(Book book, List<BookChapter> chapters);

  /// 删除书籍，章节由外键级联删除。
  Future<void> deleteBook(String bookUrl);

  /// 在一个事务中删除多本书，章节由外键级联删除。
  Future<void> deleteBooks(Set<String> bookUrls);

  /// 在一个事务中把多本书替换到指定分组位值。
  Future<void> replaceBooksGroup(Set<String> bookUrls, int groupId);
}
