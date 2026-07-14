import '../model/bookmark.dart';

/// 定义阅读器书签持久化边界，UI 和 ViewModel 不直接访问 BookmarkDao。
abstract interface class BookmarkGateway {
  /// 观察指定书名与作者关联的全部书签。
  Stream<List<Bookmark>> watchByBook(String bookName, String bookAuthor);

  /// 以创建时间主键保存或替换书签。
  Future<void> saveBookmark(Bookmark bookmark);

  /// 按创建时间主键删除书签。
  Future<void> deleteBookmark(int time);
}
