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
  Future<List<Book>> getAllBooks(
    int userId, {
    DatabaseExecutor? executor,
  }) async {
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.readingHistoryBooks,
      where: 'userId = ? orderBy=durChapterTime DESC',
      argumentCount: 1,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.readingHistoryBooks,
      where: 'userId = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'durChapterTime DESC, bookUrl ASC',
    );
    return rows.map(bookFromMap).toList(growable: false);
  }

  /// 按主键读取历史书籍快照。
  Future<Book?> getBook(
    int userId,
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.readingHistoryBooks,
      where: 'userId = ? AND bookUrl = ? limit=1',
      argumentCount: 2,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.readingHistoryBooks,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : bookFromMap(rows.first);
  }

  /// 按索引读取一本历史书籍的完整目录。
  Future<List<BookChapter>> getChapters(
    int userId,
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.readingHistoryChapters,
      where: 'userId = ? AND bookUrl = ? orderBy=`index` ASC',
      argumentCount: 2,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.readingHistoryChapters,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
      orderBy: '`index` ASC',
    );
    return rows.map(bookChapterFromMap).toList(growable: false);
  }

  /// 观察历史书籍表，提交变化后重新查询。
  Stream<List<Book>> watchAllBooks(int userId) {
    final Set<String> observedTables = <String>{
      DatabaseTables.readingHistoryBooks,
    };
    return _database.changeNotifier.watchQuery<List<Book>>(
      tableNames: observedTables,
      query: () => getAllBooks(userId),
    );
  }

  /// 在调用方事务中替换历史书籍快照。
  Future<void> upsertBook(
    int userId,
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
      <String, Object?>{'userId': userId, ...bookToMap(book)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 在调用方事务中删除一本书的旧历史目录。
  Future<void> deleteChapters(
    int userId,
    String bookUrl, {
    required DatabaseExecutor executor,
  }) async {
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.readingHistoryChapters,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    await executor.delete(
      DatabaseTables.readingHistoryChapters,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
  }

  /// 在调用方事务中写入完整历史目录。
  Future<void> upsertChapters(
    int userId,
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
        <String, Object?>{'userId': userId, ...bookChapterToMap(chapter)},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 原子更新历史阅读位置，返回受影响行数。
  Future<int> updateProgress({
    required int userId,
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
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    final int changedRows = await database.update(
      DatabaseTables.readingHistoryBooks,
      <String, Object?>{
        'durChapterIndex': chapterIndex,
        'durChapterPos': chapterPos,
        'durChapterTime': readTime,
        'durChapterTitle': chapterTitle,
      },
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
    if (changedRows > 0) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.readingHistoryBooks},
      );
    }
    return changedRows;
  }

  /// 只更新已有历史快照的用户自定义封面；没有历史记录时返回零且不新增快照。
  Future<int> updateCustomCover({
    required int userId,
    required String bookUrl,
    required String? customCoverUrl,
    DatabaseExecutor? executor,
  }) async {
    /// 当前更新使用的数据库或上层事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.readingHistoryBooks,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    /// 已有阅读历史快照的更新行数。
    final int changedRows = await writeExecutor.update(
      DatabaseTables.readingHistoryBooks,
      <String, Object?>{'customCoverUrl': customCoverUrl},
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
    if (executor == null && changedRows > 0) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.readingHistoryBooks},
      );
    }
    return changedRows;
  }

  /// 批量删除当前用户指定书籍的历史快照，历史目录由 SQLite 外键级联删除。
  Future<int> deleteBooks(
    int userId,
    Set<String> bookUrls, {
    required DatabaseExecutor executor,
  }) async {
    if (bookUrls.isEmpty) {
      return 0;
    }
    /// 批量删除使用的稳定参数占位符。
    final String placeholders =
        List<String>.filled(bookUrls.length, '?').join(',');
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.readingHistoryBooks,
      where: 'userId = ? AND bookUrl IN ($placeholders)',
      argumentCount: bookUrls.length + 1,
    );
    return executor.delete(
      DatabaseTables.readingHistoryBooks,
      where: 'userId = ? AND bookUrl IN ($placeholders)',
      whereArgs: <Object?>[userId, ...bookUrls],
    );
  }
}
