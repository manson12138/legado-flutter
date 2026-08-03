import 'package:sqflite/sqflite.dart';

import '../../constant/book_type.dart';
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
  Future<List<Book>> getAll(
    int userId, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.books,
      where: 'userId = ? orderBy=durChapterTime DESC',
      argumentCount: 1,
    );
    /// `books` 表查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.books,
      where: 'userId = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'durChapterTime DESC',
    );
    return rows.map(bookFromMap).toList(growable: false);
  }

  /// 按不经规范化的书籍 URL 主键查询一本书。
  Future<Book?> getByUrl(
    int userId,
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.books,
      where: 'userId = ? AND bookUrl = ? limit=1',
      argumentCount: 2,
    );
    /// 最多包含一行的主键查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.books,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : bookFromMap(rows.first);
  }

  /// 按书名和主要内容类型查询当前用户最近阅读的一条书架记录。
  ///
  /// Flutter 数据库只保存真实书架书，因此不需要 Android DAO 中的 `isNotShelf` 过滤条件。
  Future<Book?> getShelfBookNameConflict(
    int userId,
    String name,
    int type, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.books,
      where:
          'userId = ? AND name = ? '
          'compatiblePrimaryContentType orderBy=durChapterTime DESC, bookUrl ASC',
      argumentCount: 2,
    );
    /// 按阅读时间排序的全部同名书籍；主要类型需要按 Android 位掩码优先级判断。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.books,
      where: 'userId = ? AND name = ?',
      whereArgs: <Object?>[userId, name],
      orderBy: 'durChapterTime DESC, bookUrl ASC',
    );
    /// 当前待加入书籍决定阅读形态的主要内容类型。
    final int incomingPrimaryType = BookType.primaryContentType(type);
    for (final Map<String, Object?> row in rows) {
      /// 已存在的同名书籍。
      final Book existingBook = bookFromMap(row);
      if (BookType.primaryContentType(existingBook.type) == incomingPrimaryType) {
        return existingBook;
      }
    }
    return null;
  }

  /// 观察全部书架书；订阅后立即查询一次，此后在 `books` 提交变化时重新查询。
  Stream<List<Book>> watchAll(int userId) {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.books};
    return _database.changeNotifier.watchQuery<List<Book>>(
      tableNames: observedTables,
      query: () => getAll(userId),
    );
  }

  /// 以主键替换策略写入书籍，对应 Android `insert(REPLACE)`。
  Future<void> upsert(
    int userId,
    Book book, {
    DatabaseExecutor? executor,
  }) async {
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
      <String, Object?>{'userId': userId, ...bookToMap(book)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    }
  }

  /// 删除一本书；外键会级联删除其章节。
  Future<void> deleteByUrl(
    int userId,
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前删除使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.books,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    await writeExecutor.delete(
      DatabaseTables.books,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.books, DatabaseTables.chapters},
      );
    }
  }

  /// 批量删除指定 URL 书籍；调用方负责事务和提交后通知。
  Future<void> deleteByUrls(
    int userId,
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
      where: 'userId = ? AND bookUrl IN ($placeholders)',
      argumentCount: bookUrls.length + 1,
    );
    await executor.delete(
      DatabaseTables.books,
      where: 'userId = ? AND bookUrl IN ($placeholders)',
      whereArgs: <Object?>[userId, ...bookUrls],
    );
  }

  /// 批量替换书籍分组位值；调用方负责事务和提交后通知。
  Future<void> replaceGroup(
    int userId,
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
      where: 'userId = ? AND bookUrl IN ($placeholders)',
      argumentCount: bookUrls.length + 1,
    );
    await executor.update(
      DatabaseTables.books,
      <String, Object?>{'`group`': groupId > 0 ? groupId : 0},
      where: 'userId = ? AND bookUrl IN ($placeholders)',
      whereArgs: <Object?>[userId, ...bookUrls],
    );
  }

  /// 原子更新阅读位置与同步时间，不覆盖书籍其他字段。
  Future<int> updateProgress({
    required int userId,
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
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
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
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
    if (executor == null && changedRows > 0) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    }
    return changedRows;
  }

  /// 只更新用户自定义封面，不覆盖阅读进度、分组或书源返回的普通封面。
  Future<int> updateCustomCover({
    required int userId,
    required String bookUrl,
    required String? customCoverUrl,
    DatabaseExecutor? executor,
  }) async {
    /// 当前更新使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.books,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    /// 被更新的书籍行数，用于识别书籍已经被其他操作移除的情况。
    final int changedRows = await writeExecutor.update(
      DatabaseTables.books,
      <String, Object?>{'customCoverUrl': customCoverUrl},
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
    if (executor == null && changedRows > 0) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.books});
    }
    return changedRows;
  }
}
