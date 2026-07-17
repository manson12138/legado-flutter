import 'package:sqflite/sqflite.dart';

import '../../domain/model/book.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `books` 表查询和写入，对应 Android `BookDao` 的第一批核心能力。
final class BookDao {
  /// 创建书籍 DAO。
  const BookDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按最近阅读时间倒序查询全部书架书。
  Future<List<Book>> getAll({DatabaseExecutor? executor}) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.books,
      where: '<all> orderBy=durChapterTime DESC',
    );
    /// `books` 表查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.books,
      orderBy: 'durChapterTime DESC',
    );
    return rows.map(bookFromMap).toList(growable: false);
  }

  /// 按不经规范化的书籍 URL 主键查询一本书。
  Future<Book?> getByUrl(String bookUrl, {DatabaseExecutor? executor}) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.books,
      where: 'bookUrl = ? limit=1',
      argumentCount: 1,
    );
    /// 最多包含一行的主键查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.books,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : bookFromMap(rows.first);
  }

  /// 按书名和作者精确查询最近阅读的一条书架记录。
  ///
  /// Flutter 数据库只保存真实书架书，因此不需要 Android DAO 中的 `isNotShelf` 过滤条件。
  Future<Book?> getShelfBookConflict(
    String name,
    String author, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.books,
      where: 'name = ? AND author = ? orderBy=durChapterTime DESC limit=1',
      argumentCount: 2,
    );
    /// 最多包含一行的同名同作者查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.books,
      where: 'name = ? AND author = ?',
      whereArgs: <Object?>[name, author],
      orderBy: 'durChapterTime DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : bookFromMap(rows.first);
  }

  /// 观察全部书架书；订阅后立即查询一次，此后在 `books` 提交变化时重新查询。
  Stream<List<Book>> watchAll() async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.books};
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(
      observedTables,
    );
    while (true) {
      yield await getAll();
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 以主键替换策略写入书籍，对应 Android `insert(REPLACE)`。
  Future<void> upsert(Book book, {DatabaseExecutor? executor}) async {
    /// 当前写入使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.books,
      itemCount: 1,
    );
    await writeExecutor.insert(
      DatabaseTables.books,
      bookToMap(book),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    }
  }

  /// 删除一本书；外键会级联删除其章节。
  Future<void> deleteByUrl(String bookUrl, {DatabaseExecutor? executor}) async {
    /// 当前删除使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.books,
      where: 'bookUrl = ?',
      argumentCount: 1,
    );
    await writeExecutor.delete(
      DatabaseTables.books,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.books, DatabaseTables.chapters},
      );
    }
  }

  /// 批量删除指定 URL 书籍；调用方负责事务和提交后通知。
  Future<void> deleteByUrls(
    Set<String> bookUrls, {
    required DatabaseExecutor executor,
  }) async {
    if (bookUrls.isEmpty) {
      return;
    }
    /// 与 URL 数量一致的 SQL 占位符。
    final String placeholders = List<String>.filled(bookUrls.length, '?').join(',');
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.books,
      where: 'bookUrl IN ($placeholders)',
      argumentCount: bookUrls.length,
    );
    await executor.delete(
      DatabaseTables.books,
      where: 'bookUrl IN ($placeholders)',
      whereArgs: bookUrls.toList(growable: false),
    );
  }

  /// 批量替换书籍分组位值；调用方负责事务和提交后通知。
  Future<void> replaceGroup(
    Set<String> bookUrls,
    int groupId, {
    required DatabaseExecutor executor,
  }) async {
    if (bookUrls.isEmpty) {
      return;
    }
    /// 与 URL 数量一致的 SQL 占位符。
    final String placeholders = List<String>.filled(bookUrls.length, '?').join(',');
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.books,
      where: 'bookUrl IN ($placeholders)',
      argumentCount: bookUrls.length,
    );
    await executor.update(
      DatabaseTables.books,
      <String, Object?>{'`group`': groupId > 0 ? groupId : 0},
      where: 'bookUrl IN ($placeholders)',
      whereArgs: bookUrls.toList(growable: false),
    );
  }

  /// 原子更新阅读位置与同步时间，不覆盖书籍其他字段。
  Future<int> updateProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
    required int readTime,
    required int syncTime,
    String? chapterTitle,
    DatabaseExecutor? executor,
  }) async {
    /// 当前更新使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.books,
      where: 'bookUrl = ?',
      argumentCount: 1,
    );
    /// 被更新的书籍行数，用于区分成功和书籍不存在。
    final int changedRows = await writeExecutor.update(
      DatabaseTables.books,
      <String, Object?>{
        'durChapterIndex': chapterIndex,
        'durChapterPos': chapterPos,
        'durChapterTime': readTime,
        'durChapterTitle': chapterTitle,
        'syncTime': syncTime,
      },
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
    );
    if (executor == null && changedRows > 0) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    }
    return changedRows;
  }
}
