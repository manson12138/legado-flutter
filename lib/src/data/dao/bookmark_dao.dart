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
  Future<List<Bookmark>> getByBook(String bookName, String bookAuthor) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookmarks,
      where: 'bookName = ? AND bookAuthor = ? orderBy=chapterIndex ASC, chapterPos ASC',
      argumentCount: 2,
    );
    /// 指定书名和作者的书签行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.bookmarks,
      where: 'bookName = ? AND bookAuthor = ?',
      whereArgs: <Object?>[bookName, bookAuthor],
      orderBy: 'chapterIndex ASC, chapterPos ASC',
    );
    return rows.map(bookmarkFromMap).toList(growable: false);
  }

  /// 观察一本书的书签；书签表变化时重新查询。
  Stream<List<Bookmark>> watchByBook(String bookName, String bookAuthor) async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.bookmarks};
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(
      observedTables,
    );
    while (true) {
      yield await getByBook(bookName, bookAuthor);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 以创建时间主键替换写入书签。
  Future<void> upsert(Bookmark bookmark) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.bookmarks,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.bookmarks,
      bookmarkToMap(bookmark),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookmarks});
  }

  /// 按创建时间主键删除书签。
  Future<void> deleteByTime(int time) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.bookmarks,
      where: 'time = ?',
      argumentCount: 1,
    );
    await database.delete(
      DatabaseTables.bookmarks,
      where: 'time = ?',
      whereArgs: <Object?>[time],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookmarks});
  }
}
