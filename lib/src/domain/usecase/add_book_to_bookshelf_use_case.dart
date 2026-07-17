import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import '../model/add_book_to_bookshelf_result.dart';
import '../model/book.dart';
import '../model/book_chapter.dart';
import '../model/book_shelf_state.dart';
import 'resolve_book_shelf_state_use_case.dart';
import 'use_case_guard.dart';

/// 将书籍和已获取目录作为一个业务动作加入书架。
final class AddBookToBookshelfUseCase {
  /// 创建带书架冲突解析能力的加入书架 UseCase。
  const AddBookToBookshelfUseCase(this._gateway, this._resolveShelfState);

  /// 负责书籍和章节关联事务的数据边界。
  final BookshelfGateway _gateway;

  /// 按 Android 顺序解析精确记录与同名同作者冲突。
  final ResolveBookShelfStateUseCase _resolveShelfState;

  /// 执行面向用户的加入动作，冲突时返回结构化结果且不写数据库。
  Future<AppResult<AddBookToBookshelfResult>> execute(
    Book book,
    List<BookChapter> chapters,
  ) async {
    /// 输入结构校验结果。
    final AppFailure<void>? validationError = _validate(book, chapters);
    if (validationError != null) {
      return AppFailure<AddBookToBookshelfResult>(validationError.error);
    }
    /// 当前候选书籍的书架匹配结果。
    final AppResult<ResolvedBookShelfState> resolvedResult =
        await _resolveShelfState.execute(book);
    switch (resolvedResult) {
      case AppFailure<ResolvedBookShelfState>(error: final error):
        return AppFailure<AddBookToBookshelfResult>(error);
      case AppSuccess<ResolvedBookShelfState>(value: final resolved):
        /// 当前匹配状态命中的现有书籍。
        final Book? existingBook = resolved.existingBook;
        switch (resolved.state) {
          case BookShelfState.inShelf:
            if (existingBook == null) {
              return validationFailure<AddBookToBookshelfResult>('书架状态与现有书籍不一致');
            }
            return AppSuccess<AddBookToBookshelfResult>(
              BookAlreadyInBookshelf(existingBook),
            );
          case BookShelfState.sameNameAuthor:
            if (existingBook == null) {
              return validationFailure<AddBookToBookshelfResult>('书架冲突缺少现有书籍');
            }
            return AppSuccess<AddBookToBookshelfResult>(
              BookShelfConflict(
                existingBook: existingBook,
                incomingBook: book,
                incomingChapters: chapters,
              ),
            );
          case BookShelfState.notInShelf:
            /// 首次加入书架的数据库写入结果。
            final AppResult<void> writeResult = await save(book, chapters);
            return switch (writeResult) {
              AppSuccess<void>() => AppSuccess<AddBookToBookshelfResult>(
                BookAddedToBookshelf(book),
              ),
              AppFailure<void>(error: final error) =>
                AppFailure<AddBookToBookshelfResult>(error),
            };
        }
    }
  }

  /// 用户在冲突提示中明确选择“仍然新增一本”后写入候选书籍。
  ///
  /// 该入口只绕过同名同作者保护，仍会阻止相同 URL 覆盖现有记录。
  Future<AppResult<void>> addAsNew(Book book, List<BookChapter> chapters) async {
    /// 输入结构校验结果。
    final AppFailure<void>? validationError = _validate(book, chapters);
    if (validationError != null) {
      return validationError;
    }
    /// 防止确认对话框展示期间另一个流程已经写入相同主键。
    final AppResult<Book?> exactResult = await guardUseCase<Book?>(
      () => _gateway.getBook(book.bookUrl),
    );
    switch (exactResult) {
      case AppFailure<Book?>(error: final error):
        return AppFailure<void>(error);
      case AppSuccess<Book?>(value: final Book? existingBook):
        if (existingBook != null) {
          return validationFailure<void>('该来源书籍已经在书架中');
        }
    }
    return save(book, chapters);
  }

  /// 保存已由调用方确认身份的现有书籍更新或本地书重导结果。
  ///
  /// 书架刷新和相同内容本地书重导属于更新，不应触发面向用户的同名书冲突流程。
  Future<AppResult<void>> save(Book book, List<BookChapter> chapters) {
    /// 输入结构校验结果。
    final AppFailure<void>? validationError = _validate(book, chapters);
    if (validationError != null) {
      return Future<AppResult<void>>.value(validationError);
    }
    return guardUseCase<void>(() => _gateway.addBook(book, chapters));
  }

  /// 校验 URL、章节归属及章节索引唯一性。
  AppFailure<void>? _validate(Book book, List<BookChapter> chapters) {
    if (book.bookUrl.isEmpty) {
      return validationFailure<void>('书籍 URL 不能为空');
    }
    /// 本次目录中已经出现的章节索引。
    final Set<int> chapterIndices = <int>{};
    /// 本次目录中已经出现的 URL 与书籍 URL 复合键。
    final Set<(String, String)> chapterKeys = <(String, String)>{};
    for (final BookChapter chapter in chapters) {
      if (chapter.bookUrl != book.bookUrl) {
        return validationFailure<void>('章节所属书籍与目标书籍不一致');
      }
      if (!chapterIndices.add(chapter.index)) {
        return validationFailure<void>('同一本书的章节索引不能重复');
      }
      /// 与数据库 `(url, bookUrl)` 主键对应的内存复合键。
      final (String, String) chapterKey = (chapter.bookUrl, chapter.url);
      if (!chapterKeys.add(chapterKey)) {
        return validationFailure<void>('同一本书的章节 URL 不能重复');
      }
    }
    return null;
  }
}
