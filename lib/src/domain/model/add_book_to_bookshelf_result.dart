import 'book.dart';
import 'book_chapter.dart';

/// 表示一次面向用户的加入书架动作得到的结构化业务结果。
sealed class AddBookToBookshelfResult {
  /// 限制结果只能由本文件中的明确类型创建。
  const AddBookToBookshelfResult();
}

/// 表示候选书籍和目录已经成功写入书架。
final class BookAddedToBookshelf extends AddBookToBookshelfResult {
  /// 创建加入成功结果。
  const BookAddedToBookshelf(this.book);

  /// 已经写入书架的候选书籍。
  final Book book;
}

/// 表示同一个书籍 URL 已经在书架中，本次没有覆盖写入。
final class BookAlreadyInBookshelf extends AddBookToBookshelfResult {
  /// 创建精确重复结果。
  const BookAlreadyInBookshelf(this.existingBook);

  /// 书架中已经存在的精确记录。
  final Book existingBook;
}

/// 表示书架存在同名同作者的另一来源，需要用户明确选择处理方式。
final class BookShelfConflict extends AddBookToBookshelfResult {
  /// 创建包含现有书和候选书事实的冲突结果。
  BookShelfConflict({
    required this.existingBook,
    required this.incomingBook,
    required List<BookChapter> incomingChapters,
  }) : incomingChapters = List<BookChapter>.unmodifiable(incomingChapters);

  /// 当前书架中的同名同作者书籍。
  final Book existingBook;

  /// 用户正在尝试加入的新书源书籍。
  final Book incomingBook;

  /// 已获取且属于新书源书籍的完整目录。
  final List<BookChapter> incomingChapters;
}
