import 'package:sqflite/sqflite.dart';

import '../../domain/model/book_group.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `book_groups` 表查询和写入，对应 Android `BookGroupDao`。
final class BookGroupDao {
  /// 创建书架分组 DAO。
  const BookGroupDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按显示顺序读取全部系统和用户分组。
  Future<List<BookGroup>> getAll() async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 全部分组数据库行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.bookGroups,
      orderBy: '`order` ASC',
    );
    return rows.map(bookGroupFromMap).toList(growable: false);
  }

  /// 按分组主键查询单个分组。
  Future<BookGroup?> getById(int groupId) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 最多包含一个分组的主键查询结果。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.bookGroups,
      where: 'groupId = ?',
      whereArgs: <Object?>[groupId],
      limit: 1,
    );
    return rows.isEmpty ? null : bookGroupFromMap(rows.first);
  }

  /// 观察全部分组；表变化时重新查询。
  Stream<List<BookGroup>> watchAll() async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.bookGroups};
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

  /// 替换写入一个分组。
  Future<void> upsert(BookGroup group) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    await database.insert(
      DatabaseTables.bookGroups,
      bookGroupToMap(group),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookGroups});
  }

  /// 按主键删除分组；书籍上的位掩码由业务 UseCase 另行协调。
  Future<void> deleteById(int groupId) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    await database.delete(
      DatabaseTables.bookGroups,
      where: 'groupId = ?',
      whereArgs: <Object?>[groupId],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookGroups});
  }
}
