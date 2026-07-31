import 'package:sqflite/sqflite.dart';

import '../../domain/model/search_book.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 负责详情页精确书源候选的查询和整组事务覆盖。
final class BookSourceCandidateDao {
  /// 创建绑定 Flutter 独立数据库的候选 DAO。
  const BookSourceCandidateDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按严格书名作者及搜索点击时的组内顺序读取候选。
  Future<List<SearchBook>> loadByNameAuthor(
    String name,
    String author,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookSourceCandidates,
      where: 'name = ? AND author = ? orderBy=candidateOrder ASC',
      argumentCount: 2,
    );
    /// 当前书籍持久化的候选行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.bookSourceCandidates,
      where: 'name = ? AND author = ?',
      whereArgs: <Object?>[name, author],
      orderBy: 'candidateOrder ASC',
    );
    return rows
        .map(searchBookFromSourceCandidateMap)
        .toList(growable: false);
  }

  /// 在同一事务删除旧组并写入新组，失败时完整保留旧快照。
  Future<void> replaceByNameAuthor(
    String name,
    String author,
    List<SearchBook> books,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 当前点击快照的统一捕获时间。
    final int capturedAt = DateTime.now().millisecondsSinceEpoch;
    _database.logOperation(
      operation: 'TRANSACTION_REPLACE_GROUP',
      table: DatabaseTables.bookSourceCandidates,
      where: 'name = ? AND author = ?',
      argumentCount: 2,
      itemCount: books.length,
    );
    await database.transaction<void>((Transaction transaction) async {
      await transaction.delete(
        DatabaseTables.bookSourceCandidates,
        where: 'name = ? AND author = ?',
        whereArgs: <Object?>[name, author],
      );
      /// 同一事务内批量写入候选，避免逐行提交产生中间状态。
      final Batch batch = transaction.batch();
      for (int index = 0; index < books.length; index += 1) {
        /// 当前按搜索结果稳定顺序写入的候选。
        final SearchBook book = books[index];
        batch.insert(
          DatabaseTables.bookSourceCandidates,
          bookSourceCandidateToMap(
            book,
            candidateOrder: index,
            capturedAt: capturedAt,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    _database.changeNotifier.notifyTables(
      <String>{DatabaseTables.bookSourceCandidates},
    );
  }
}
