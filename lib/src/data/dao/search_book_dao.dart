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
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.searchBooks,
      where: 'name = ? AND author = ? orderBy=originOrder ASC limit=1',
      argumentCount: 2,
    );
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

  /// 按书名精确或包含关系读取最近的非空封面缓存，并限制返回规模。
  Future<List<SearchBook>> loadCoverCandidates(
    String name, {
    int limit = 200,
  }) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 对 SQLite LIKE 通配符转义后的目标书名。
    final String escapedName = name
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    _database.logOperation(
      operation: 'SELECT_JOIN',
      table: DatabaseTables.searchBooks,
      where:
          'enabled source AND non-empty cover AND '
          '(name exact OR bidirectional contains) limit=$limit',
      argumentCount: 4,
    );
    /// 先在 SQLite 中压缩候选规模，最终三级匹配仍由领域协调器统一完成。
    final List<Map<String, Object?>> rows = await database.rawQuery(
      '''
      SELECT searchBooks.*
      FROM searchBooks
      INNER JOIN book_sources
        ON book_sources.bookSourceUrl = searchBooks.origin
      WHERE book_sources.enabled = 1
        AND TRIM(COALESCE(searchBooks.coverUrl, '')) <> ''
        AND (
          searchBooks.name = ? COLLATE NOCASE
          OR searchBooks.name LIKE ? ESCAPE '\\' COLLATE NOCASE
          OR ? LIKE '%' || searchBooks.name || '%' COLLATE NOCASE
        )
      ORDER BY book_sources.customOrder ASC, searchBooks.time DESC
      LIMIT ?
      ''',
      <Object?>[name, '%$escapedName%', name, limit],
    );
    return rows.map(searchBookFromMap).toList(growable: false);
  }

  /// 批量替换写入搜索结果。
  Future<void> upsertAll(List<SearchBook> books) async {
    if (books.isEmpty) {
      return;
    }
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'BATCH_INSERT_REPLACE',
      table: DatabaseTables.searchBooks,
      itemCount: books.length,
    );
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
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.searchBooks,
      where: 'time < ?',
      argumentCount: 1,
    );
    await database.delete(
      DatabaseTables.searchBooks,
      where: 'time < ?',
      whereArgs: <Object?>[time],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.searchBooks});
  }
}
