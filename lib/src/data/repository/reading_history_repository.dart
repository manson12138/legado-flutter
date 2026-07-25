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
