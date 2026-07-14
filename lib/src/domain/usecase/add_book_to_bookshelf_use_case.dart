import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import '../model/book.dart';
import '../model/book_chapter.dart';
import 'use_case_guard.dart';

/// 将书籍和已获取目录作为一个业务动作加入书架。
final class AddBookToBookshelfUseCase {
  /// 创建加入书架 UseCase。
  const AddBookToBookshelfUseCase(this._gateway);

  /// 负责书籍和章节关联事务的领域边界。
  final BookshelfGateway _gateway;

  /// 校验 URL、章节归属及章节索引唯一性后执行事务写入。
  Future<AppResult<void>> execute(Book book, List<BookChapter> chapters) {
    if (book.bookUrl.isEmpty) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('书籍 URL 不能为空'),
      );
    }

    /// 本次目录中已经出现的章节索引。
    final Set<int> chapterIndices = <int>{};
    /// 本次目录中已经出现的 URL 与书籍 URL 复合键。
    final Set<(String, String)> chapterKeys = <(String, String)>{};
    for (final BookChapter chapter in chapters) {
      if (chapter.bookUrl != book.bookUrl) {
        return Future<AppResult<void>>.value(
          validationFailure<void>('章节所属书籍与目标书籍不一致'),
        );
      }
      if (!chapterIndices.add(chapter.index)) {
        return Future<AppResult<void>>.value(
          validationFailure<void>('同一本书的章节索引不能重复'),
        );
      }
      /// 与数据库 `(url, bookUrl)` 主键对应的内存复合键。
      final (String, String) chapterKey = (chapter.bookUrl, chapter.url);
      if (!chapterKeys.add(chapterKey)) {
        return Future<AppResult<void>>.value(
          validationFailure<void>('同一本书的章节 URL 不能重复'),
        );
      }
    }
    return guardUseCase<void>(() => _gateway.addBook(book, chapters));
  }
}
