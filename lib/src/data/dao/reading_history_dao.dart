import 'package:sqflite/sqflite.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 负责阅读历史书籍和目录快照的 SQLite 读写。
final class ReadingHistoryDao {
  /// 创建阅读历史 DAO。
  const ReadingHistoryDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按最后阅读时间倒序读取全部历史书籍。
  Future<List<Book>> getAllBooks({DatabaseExecutor? executor}) async {
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.readingHistoryBooks,
      where: '<all> orderBy=durChapterTime DESC',
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.readingHistoryBooks,
      orderBy: 'durChapterTime DESC, bookUrl ASC',
    );
    return rows.map(bookFromMap).toList(growable: false);
  }

  /// 按主键读取历史书籍快照。
  Future<Book?> getBook(
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.readingHistoryBooks,
      where: 'bookUrl = ? limit=1',
      argumentCount: 1,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.readingHistoryBooks,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : bookFromMap(rows.first);
  }

  /// 按索引读取一本历史书籍的完整目录。
  Future<List<BookChapter>> getChapters(
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.readingHistoryChapters,
      where: 'bookUrl = ? orderBy=`index` ASC',
      argumentCount: 1,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.readingHistoryChapters,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
      orderBy: '`index` ASC',
    );
    return rows.map(bookChapterFromMap).toList(growable: false);
  }

  /// 观察历史书籍表，提交变化后重新查询。
  Stream<List<Book>> watchAllBooks() async* {
    final Set<String> observedTables = <String>{
      DatabaseTables.readingHistoryBooks,
    };
    int observedRevision =
        _database.changeNotifier.revisionForTables(observedTables);
    while (true) {
      yield await getAllBooks();
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 在调用方事务中替换历史书籍快照。
  Future<void> upsertBook(
    Book book, {
    required DatabaseExecutor executor,
  }) async {
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.readingHistoryBooks,
      itemCount: 1,
    );
    await executor.insert(
      DatabaseTables.readingHistoryBooks,
      bookToMap(book),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 在调用方事务中删除一本书的旧历史目录。
  Future<void> deleteChapters(
    String bookUrl, {
    required DatabaseExecutor executor,
  }) async {
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.readingHistoryChapters,
      where: 'bookUrl = ?',
      argumentCount: 1,
    );
    await executor.delete(
      DatabaseTables.readingHistoryChapters,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
    );
  }

  /// 在调用方事务中写入完整历史目录。
  Future<void> upsertChapters(
    List<BookChapter> chapters, {
    required DatabaseExecutor executor,
  }) async {
    if (chapters.isEmpty) {
      return;
    }
    _database.logOperation(
      operation: 'BATCH_INSERT_REPLACE',
      table: DatabaseTables.readingHistoryChapters,
      itemCount: chapters.length,
    );
    final Batch batch = executor.batch();
    for (final BookChapter chapter in chapters) {
      batch.insert(
        DatabaseTables.readingHistoryChapters,
        bookChapterToMap(chapter),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 原子更新历史阅读位置，返回受影响行数。
  Future<int> updateProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
    required int readTime,
    required String? chapterTitle,
  }) async {
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.readingHistoryBooks,
      where: 'bookUrl = ?',
      argumentCount: 1,
    );
    final int changedRows = await database.update(
      DatabaseTables.readingHistoryBooks,
      <String, Object?>{
        'durChapterIndex': chapterIndex,
        'durChapterPos': chapterPos,
        'durChapterTime': readTime,
        'durChapterTitle': chapterTitle,
      },
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
    );
    if (changedRows > 0) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.readingHistoryBooks},
      );
    }
    return changedRows;
  }
}
