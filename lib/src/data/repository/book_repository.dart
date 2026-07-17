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
  const BookRepository(this._database, this._bookDao, this._chapterDao);

  /// 用于关键关联事务和提交后通知的数据库入口。
  final LegadoDatabase _database;
  /// `books` 表 DAO。
  final BookDao _bookDao;
  /// `chapters` 表 DAO。
  final BookChapterDao _chapterDao;

  /// 观察书架并转换底层流错误。
  @override
  Stream<List<Book>> watchBookshelf() {
    return guardDataStream<List<Book>>(_bookDao.watchAll());
  }

  /// 按书籍 URL 查询书架书。
  @override
  Future<Book?> getBook(String bookUrl) {
    return guardDataOperation<Book?>(() => _bookDao.getByUrl(bookUrl));
  }

  /// 按 Android 精确语义查询同名同作者的最近阅读书籍。
  @override
  Future<Book?> getShelfBookConflict(String name, String author) {
    return guardDataOperation<Book?>(
      () => _bookDao.getShelfBookConflict(name, author),
    );
  }

  /// 原子写入书籍和目录，避免出现目录已保存但书籍缺失的中间状态。
  @override
  Future<void> addBook(Book book, List<BookChapter> chapters) {
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _bookDao.upsert(book, executor: transaction);
        if (chapters.isNotEmpty) {
          await _chapterDao.deleteByBook(book.bookUrl, executor: transaction);
          await _chapterDao.upsertAll(chapters, executor: transaction);
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
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        /// 事务开始时仍然存在的旧书记录，防止并发删除后重新制造新书。
        final Book? existingOldBook = await _bookDao.getByUrl(
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
          newBook.bookUrl,
          executor: transaction,
        );
        if (conflictingBook != null && conflictingBook.bookUrl != oldBookUrl) {
          throw const AppError(
            kind: AppErrorKind.validation,
            message: '目标来源的书籍已经在书架中，请先处理重复书籍',
          );
        }
        await _bookDao.deleteByUrl(oldBookUrl, executor: transaction);
        await _bookDao.upsert(newBook, executor: transaction);
        await _chapterDao.upsertAll(chapters, executor: transaction);
      });
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.books, DatabaseTables.chapters},
      );
    });
  }

  /// 删除书籍，并依赖已启用的 SQLite 外键级联删除目录。
  @override
  Future<void> deleteBook(String bookUrl) {
    return guardDataOperation<void>(() => _bookDao.deleteByUrl(bookUrl));
  }

  /// 在一个事务中批量删除书籍，章节由数据库外键级联删除。
  @override
  Future<void> deleteBooks(Set<String> bookUrls) {
    return guardDataOperation<void>(() async {
      if (bookUrls.isEmpty) {
        return;
      }
      await _database.transaction<void>((transaction) async {
        await _bookDao.deleteByUrls(bookUrls, executor: transaction);
      });
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.books, DatabaseTables.chapters},
      );
    });
  }

  /// 在一个事务中替换多本书的用户分组位值。
  @override
  Future<void> replaceBooksGroup(Set<String> bookUrls, int groupId) {
    return guardDataOperation<void>(() async {
      if (bookUrls.isEmpty) {
        return;
      }
      await _database.transaction<void>((transaction) async {
        await _bookDao.replaceGroup(bookUrls, groupId, executor: transaction);
      });
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    });
  }

  /// 按索引升序读取完整目录。
  @override
  Future<List<BookChapter>> getChapterList(String bookUrl) {
    return guardDataOperation<List<BookChapter>>(
      () => _chapterDao.getChapterList(bookUrl),
    );
  }

  /// 观察目录并转换底层流错误。
  @override
  Stream<List<BookChapter>> watchChapterList(String bookUrl) {
    return guardDataStream<List<BookChapter>>(
      _chapterDao.watchChapterList(bookUrl),
    );
  }

  /// 在事务中整体替换一本书的目录。
  @override
  Future<void> replaceChapterList(
    String bookUrl,
    List<BookChapter> chapters,
  ) {
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _chapterDao.deleteByBook(bookUrl, executor: transaction);
        await _chapterDao.upsertAll(chapters, executor: transaction);
      });
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.chapters});
    });
  }

  /// 原子更新阅读位置；返回 false 表示目标书籍已不存在。
  @override
  Future<bool> saveProgress(ReadingProgress progress) {
    return guardDataOperation<bool>(() async {
      /// 被阅读进度更新命中的书籍行数。
      final int changedRows = await _bookDao.updateProgress(
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
    return guardDataOperation<ReadingProgress?>(() async {
      /// 包含阅读位置的书架书；不存在时不制造空进度。
      final Book? book = await _bookDao.getByUrl(bookUrl);
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
