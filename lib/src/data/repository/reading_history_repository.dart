import '../../domain/gateway/reading_history_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../dao/reading_history_dao.dart';
import '../local/data_error.dart';
import '../local/database_tables.dart';
import '../local/legado_database.dart';

/// 使用独立 SQLite 快照实现阅读历史领域边界。
final class ReadingHistoryRepository implements ReadingHistoryGateway {
  /// 创建阅读历史 Repository。
  const ReadingHistoryRepository(
    this._database,
    this._dao,
    this._requireUserId,
  );

  /// 事务和提交后通知使用的数据库入口。
  final LegadoDatabase _database;

  /// 阅读历史 DAO。
  final ReadingHistoryDao _dao;

  /// 返回当前认证用户 ID；阅读历史绝不使用空用户或设备级回退。
  final int Function() _requireUserId;

  @override
  Stream<List<Book>> watchHistory() {
    final int userId = _requireUserId();
    return guardDataStream<List<Book>>(_dao.watchAllBooks(userId));
  }

  @override
  Future<Book?> getHistoryBook(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<Book?>(
      () => _dao.getBook(userId, bookUrl),
    );
  }

  @override
  Future<List<BookChapter>> getHistoryChapters(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<List<BookChapter>>(
      () => _dao.getChapters(userId, bookUrl),
    );
  }

  @override
  Future<void> recordHistory(Book book, List<BookChapter> chapters) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _dao.upsertBook(userId, book, executor: transaction);
        await _dao.deleteChapters(
          userId,
          book.bookUrl,
          executor: transaction,
        );
        await _dao.upsertChapters(
          userId,
          chapters,
          executor: transaction,
        );
      });
      _database.changeNotifier.notifyTables(<String>{
        DatabaseTables.readingHistoryBooks,
        DatabaseTables.readingHistoryChapters,
      });
    });
  }

  /// 在事务内确认历史成员仍存在后再替换快照，关闭用户删除与后台刷新之间的复活窗口。
  @override
  Future<bool> refreshExistingHistory(
    Book book,
    List<BookChapter> chapters,
  ) {
    /// 当前游客或登录账号的历史数据作用域。
    final int userId = _requireUserId();
    return guardDataOperation<bool>(() async {
      /// 本次事务是否实际刷新了仍存在的历史成员。
      bool refreshed = false;
      await _database.transaction<void>((transaction) async {
        /// 事务内重新读取的历史成员事实。
        final Book? existingBook = await _dao.getBook(
          userId,
          book.bookUrl,
          executor: transaction,
        );
        if (existingBook == null) {
          return;
        }
        /// 合并事务内最新进度和用户封面后的历史书籍，避免后台旧快照覆盖用户事实。
        final Book refreshedBook = book
            .copyWithProgress(
              chapterIndex: existingBook.durChapterIndex,
              chapterPos: existingBook.durChapterPos,
              readTime: existingBook.durChapterTime,
              chapterTitle: existingBook.durChapterTitle,
            )
            .copyWithCustomCover(existingBook.customCoverUrl);
        await _dao.upsertBook(
          userId,
          refreshedBook,
          executor: transaction,
        );
        await _dao.deleteChapters(
          userId,
          book.bookUrl,
          executor: transaction,
        );
        await _dao.upsertChapters(
          userId,
          chapters,
          executor: transaction,
        );
        refreshed = true;
      });
      if (refreshed) {
        _database.changeNotifier.notifyTables(<String>{
          DatabaseTables.readingHistoryBooks,
          DatabaseTables.readingHistoryChapters,
        });
      }
      return refreshed;
    });
  }

  /// 在单一事务中删除历史书籍，让目录外键级联并在提交后统一刷新页面观察者。
  @override
  Future<void> deleteHistory(Set<String> bookUrls) {
    /// 当前游客或登录账号的历史数据作用域。
    final int userId = _requireUserId();
    return guardDataOperation<void>(() async {
      if (bookUrls.isEmpty) {
        return;
      }
      await _database.transaction<void>((transaction) async {
        await _dao.deleteBooks(
          userId,
          bookUrls,
          executor: transaction,
        );
      });
      _database.changeNotifier.notifyTables(<String>{
        DatabaseTables.readingHistoryBooks,
        DatabaseTables.readingHistoryChapters,
      });
    });
  }

  @override
  Future<bool> updateHistoryProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
    required int readTime,
    required String? chapterTitle,
  }) {
    final int userId = _requireUserId();
    return guardDataOperation<bool>(() async {
      final int changedRows = await _dao.updateProgress(
        userId: userId,
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        chapterPos: chapterPos,
        readTime: readTime,
        chapterTitle: chapterTitle,
      );
      return changedRows > 0;
    });
  }
}
