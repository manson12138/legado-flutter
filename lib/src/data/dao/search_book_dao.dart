import 'package:sqflite/sqflite.dart';

import '../../domain/model/search_book.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `searchBooks` 临时搜索缓存，对应 Android `SearchBookDao`。
final class SearchBookDao {
  /// 创建搜索结果 DAO。
  const SearchBookDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按书名和作者读取排序最靠前的一条换源候选。
  Future<SearchBook?> getFirstByNameAuthor(String name, String author) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 最多包含一条候选的查询结果。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.searchBooks,
      where: 'name = ? AND author = ?',
      whereArgs: <Object?>[name, author],
      orderBy: 'originOrder ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : searchBookFromMap(rows.first);
  }

  /// 批量替换写入搜索结果。
  Future<void> upsertAll(List<SearchBook> books) async {
    if (books.isEmpty) {
      return;
    }
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 聚合本次搜索结果写入的批次。
    final Batch batch = database.batch();
    for (final SearchBook book in books) {
      batch.insert(
        DatabaseTables.searchBooks,
        searchBookToMap(book),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.searchBooks});
  }

  /// 删除早于指定毫秒时间戳的搜索缓存。
  Future<void> clearExpired(int time) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    await database.delete(
      DatabaseTables.searchBooks,
      where: 'time < ?',
      whereArgs: <Object?>[time],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.searchBooks});
  }
}
