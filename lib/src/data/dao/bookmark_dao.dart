import 'package:sqflite/sqflite.dart';

import '../../domain/model/bookmark.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `bookmarks` 表查询和写入，对应 Android `BookmarkDao`。
final class BookmarkDao {
  /// 创建书签 DAO。
  const BookmarkDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按章节位置读取一本书的书签。
  Future<List<Bookmark>> getByBook(
    int userId,
    String bookName,
    String bookAuthor,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookmarks,
      where: 'userId = ? AND bookName = ? AND bookAuthor = ? orderBy=chapterIndex ASC, chapterPos ASC',
      argumentCount: 3,
    );
    /// 指定书名和作者的书签行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.bookmarks,
      where: 'userId = ? AND bookName = ? AND bookAuthor = ?',
      whereArgs: <Object?>[userId, bookName, bookAuthor],
      orderBy: 'chapterIndex ASC, chapterPos ASC',
    );
    return rows.map(bookmarkFromMap).toList(growable: false);
  }

  /// 观察一本书的书签；书签表变化时重新查询。
  Stream<List<Bookmark>> watchByBook(
    int userId,
    String bookName,
    String bookAuthor,
  ) async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.bookmarks};
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(
      observedTables,
    );
    while (true) {
      yield await getByBook(userId, bookName, bookAuthor);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 以创建时间主键替换写入书签。
  Future<void> upsert(int userId, Bookmark bookmark) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.bookmarks,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.bookmarks,
      <String, Object?>{'userId': userId, ...bookmarkToMap(bookmark)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookmarks});
  }

  /// 按创建时间主键删除书签。
  Future<void> deleteByTime(int userId, int time) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.bookmarks,
      where: 'userId = ? AND time = ?',
      argumentCount: 2,
    );
    await database.delete(
      DatabaseTables.bookmarks,
      where: 'userId = ? AND time = ?',
      whereArgs: <Object?>[userId, time],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookmarks});
  }

  /// 读取当前账号全部书签，供逻辑备份导出使用。
  Future<List<Bookmark>> getAll(
    int userId, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或备份只读事务。
    final DatabaseExecutor queryExecutor = executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookmarks,
      where: 'userId = ? orderBy=time ASC',
      argumentCount: 1,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.bookmarks,
      where: 'userId = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'time ASC',
    );
    return rows.map(bookmarkFromMap).toList(growable: false);
  }
}
