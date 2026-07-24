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
  const ReadingHistoryRepository(this._database, this._dao);

  /// 事务和提交后通知使用的数据库入口。
  final LegadoDatabase _database;

  /// 阅读历史 DAO。
  final ReadingHistoryDao _dao;

  @override
  Stream<List<Book>> watchHistory() {
    return guardDataStream<List<Book>>(_dao.watchAllBooks());
  }

  @override
  Future<Book?> getHistoryBook(String bookUrl) {
    return guardDataOperation<Book?>(() => _dao.getBook(bookUrl));
  }

  @override
  Future<List<BookChapter>> getHistoryChapters(String bookUrl) {
    return guardDataOperation<List<BookChapter>>(
      () => _dao.getChapters(bookUrl),
    );
  }

  @override
  Future<void> recordHistory(Book book, List<BookChapter> chapters) {
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _dao.upsertBook(book, executor: transaction);
        await _dao.deleteChapters(book.bookUrl, executor: transaction);
        await _dao.upsertChapters(chapters, executor: transaction);
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
    return guardDataOperation<bool>(() async {
      final int changedRows = await _dao.updateProgress(
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
