import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/chapter_gateway.dart';
import '../../domain/gateway/reading_progress_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/reading_progress.dart';
import '../../help/error/app_error.dart';
import '../dao/book_chapter_dao.dart';
import '../dao/book_dao.dart';
import '../local/data_error.dart';
import '../local/database_tables.dart';
import '../local/legado_database.dart';

/// 组合书籍和章节 DAO，实现书架、目录及阅读进度领域边界。
final class BookRepository
    implements BookshelfGateway, ChapterGateway, ReadingProgressGateway {
  /// 创建核心书籍 Repository。
  const BookRepository(
    this._database,
    this._bookDao,
    this._chapterDao,
    this._requireUserId,
  );

  /// 用于关键关联事务和提交后通知的数据库入口。
  final LegadoDatabase _database;
  /// `books` 表 DAO。
  final BookDao _bookDao;
  /// `chapters` 表 DAO。
  final BookChapterDao _chapterDao;

  /// 返回当前认证用户 ID；未登录访问会由应用作用域抛出明确错误。
  final int Function() _requireUserId;

  /// 观察书架并转换底层流错误。
  @override
  Stream<List<Book>> watchBookshelf() {
    final int userId = _requireUserId();
    return guardDataStream<List<Book>>(_bookDao.watchAll(userId));
  }

  /// 按书籍 URL 查询书架书。
  @override
  Future<Book?> getBook(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<Book?>(
      () => _bookDao.getByUrl(userId, bookUrl),
    );
  }

  /// 按 Android 精确语义查询同名同作者的最近阅读书籍。
  @override
  Future<Book?> getShelfBookConflict(String name, String author) {
    final int userId = _requireUserId();
    return guardDataOperation<Book?>(
      () => _bookDao.getShelfBookConflict(userId, name, author),
    );
  }

  /// 原子写入书籍和目录，避免出现目录已保存但书籍缺失的中间状态。
  @override
  Future<void> addBook(Book book, List<BookChapter> chapters) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _bookDao.upsert(userId, book, executor: transaction);
        if (chapters.isNotEmpty) {
          await _chapterDao.deleteByBook(
            userId,
            book.bookUrl,
            executor: transaction,
          );
          await _chapterDao.upsertAll(
            userId,
            chapters,
            executor: transaction,
          );
        }
      });
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.books, DatabaseTables.chapters},
      );
    });
  }

  /// 原子替换书籍主键和目录，并阻止覆盖书架中另一条已存在记录。
  @override
  Future<void> changeBookSource({
    required String oldBookUrl,
    required Book newBook,
    required List<BookChapter> chapters,
  }) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        /// 事务开始时仍然存在的旧书记录，防止并发删除后重新制造新书。
        final Book? existingOldBook = await _bookDao.getByUrl(
          userId,
          oldBookUrl,
          executor: transaction,
        );
        if (existingOldBook == null) {
          throw const AppError(
            kind: AppErrorKind.validation,
            message: '原书籍已不在书架中，换源已取消',
          );
        }
        /// 事务内重新读取的新主键记录，关闭预检查与提交之间的覆盖窗口。
        final Book? conflictingBook = await _bookDao.getByUrl(
          userId,
          newBook.bookUrl,
          executor: transaction,
        );
        if (conflictingBook != null && conflictingBook.bookUrl != oldBookUrl) {
          throw const AppError(
            kind: AppErrorKind.validation,
            message: '目标来源的书籍已经在书架中，请先处理重复书籍',
          );
        }
        await _bookDao.deleteByUrl(
          userId,
          oldBookUrl,
          executor: transaction,
        );
        await _bookDao.upsert(userId, newBook, executor: transaction);
        await _chapterDao.upsertAll(
          userId,
          chapters,
          executor: transaction,
        );
        /// 用户正文标注属于书籍事实，整书换源时随新主键迁移且保留章节锚点。
        await transaction.update(
          DatabaseTables.bookContentProcesses,
          <String, Object?>{'bookUrl': newBook.bookUrl},
          where: 'bookUrl = ?',
          whereArgs: <Object?>[oldBookUrl],
        );
      });
      _database.changeNotifier.notifyTables(
        <String>{
          DatabaseTables.books,
          DatabaseTables.chapters,
          DatabaseTables.bookContentProcesses,
        },
      );
    });
  }

  /// 删除书籍，同时清理没有外键约束的用户正文标注，目录继续由外键级联删除。
  @override
  Future<void> deleteBook(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await transaction.delete(
          DatabaseTables.bookContentProcesses,
          where: 'bookUrl = ?',
          whereArgs: <Object?>[bookUrl],
        );
        await _bookDao.deleteByUrl(
          userId,
          bookUrl,
          executor: transaction,
        );
      });
      _database.changeNotifier.notifyTables(
        <String>{
          DatabaseTables.books,
          DatabaseTables.chapters,
          DatabaseTables.bookContentProcesses,
        },
      );
    });
  }

  /// 在一个事务中批量删除书籍和用户正文标注，章节由数据库外键级联删除。
  @override
  Future<void> deleteBooks(Set<String> bookUrls) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      if (bookUrls.isEmpty) {
        return;
      }
      await _database.transaction<void>((transaction) async {
        /// 批量删除使用的稳定参数占位符。
        final String placeholders =
            List<String>.filled(bookUrls.length, '?').join(',');
        await transaction.delete(
          DatabaseTables.bookContentProcesses,
          where: 'bookUrl IN ($placeholders)',
          whereArgs: bookUrls.toList(growable: false),
        );
        await _bookDao.deleteByUrls(
          userId,
          bookUrls,
          executor: transaction,
        );
      });
      _database.changeNotifier.notifyTables(
        <String>{
          DatabaseTables.books,
          DatabaseTables.chapters,
          DatabaseTables.bookContentProcesses,
        },
      );
    });
  }

  /// 在一个事务中替换多本书的用户分组位值。
  @override
  Future<void> replaceBooksGroup(Set<String> bookUrls, int groupId) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      if (bookUrls.isEmpty) {
        return;
      }
      await _database.transaction<void>((transaction) async {
        await _bookDao.replaceGroup(
          userId,
          bookUrls,
          groupId,
          executor: transaction,
        );
      });
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    });
  }

  /// 按索引升序读取完整目录。
  @override
  Future<List<BookChapter>> getChapterList(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<List<BookChapter>>(
      () => _chapterDao.getChapterList(userId, bookUrl),
    );
  }

  /// 观察目录并转换底层流错误。
  @override
  Stream<List<BookChapter>> watchChapterList(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataStream<List<BookChapter>>(
      _chapterDao.watchChapterList(userId, bookUrl),
    );
  }

  /// 在事务中整体替换一本书的目录。
  @override
  Future<void> replaceChapterList(
    String bookUrl,
    List<BookChapter> chapters,
  ) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _chapterDao.deleteByBook(
          userId,
          bookUrl,
          executor: transaction,
        );
        await _chapterDao.upsertAll(
          userId,
          chapters,
          executor: transaction,
        );
      });
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.chapters});
    });
  }

  /// 原子更新阅读位置；返回 false 表示目标书籍已不存在。
  @override
  Future<bool> saveProgress(ReadingProgress progress) {
    final int userId = _requireUserId();
    return guardDataOperation<bool>(() async {
      /// 被阅读进度更新命中的书籍行数。
      final int changedRows = await _bookDao.updateProgress(
        userId: userId,
        bookUrl: progress.bookUrl,
        chapterIndex: progress.chapterIndex,
        chapterPos: progress.chapterPos,
        readTime: progress.readTime,
        chapterTitle: progress.chapterTitle,
        syncTime: progress.syncTime,
      );
      return changedRows > 0;
    });
  }

  /// 从书籍持久化字段恢复阅读位置。
  @override
  Future<ReadingProgress?> restoreProgress(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<ReadingProgress?>(() async {
      /// 包含阅读位置的书架书；不存在时不制造空进度。
      final Book? book = await _bookDao.getByUrl(userId, bookUrl);
      if (book == null) {
        return null;
      }
      return ReadingProgress(
        bookUrl: book.bookUrl,
        chapterIndex: book.durChapterIndex,
        chapterPos: book.durChapterPos,
        readTime: book.durChapterTime,
        chapterTitle: book.durChapterTitle,
        syncTime: book.syncTime,
      );
    });
  }
}
