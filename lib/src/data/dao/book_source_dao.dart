import 'package:sqflite/sqflite.dart';

import '../../domain/model/book_source.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `book_sources` 表查询和写入，对应 Android `BookSourceDao` 的核心能力。
final class BookSourceDao {
  /// 创建书源 DAO。
  const BookSourceDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按手动顺序读取全部书源。
  Future<List<BookSource>> getAll({DatabaseExecutor? executor}) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookSources,
      where: '<all> orderBy=customOrder ASC',
    );
    /// 全部书源数据库行。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.bookSources,
      orderBy: 'customOrder ASC',
    );
    return rows.map(bookSourceFromMap).toList(growable: false);
  }

  /// 按原始书源 URL 主键查询书源。
  Future<BookSource?> getByUrl(
    String sourceUrl, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookSources,
      where: 'bookSourceUrl = ? limit=1',
      argumentCount: 1,
    );
    /// 最多包含一个书源的主键查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.bookSources,
      where: 'bookSourceUrl = ?',
      whereArgs: <Object?>[sourceUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : bookSourceFromMap(rows.first);
  }

  /// 读取全部启用书源，供后续搜索和规则层使用。
  Future<List<BookSource>> getEnabled({DatabaseExecutor? executor}) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookSources,
      where: 'enabled = 1 orderBy=customOrder ASC',
    );
    /// 启用书源数据库行。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.bookSources,
      where: 'enabled = 1',
      orderBy: 'customOrder ASC',
    );
    return rows.map(bookSourceFromMap).toList(growable: false);
  }

  /// 替换写入单个书源。
  Future<void> upsert(
    BookSource source, {
    DatabaseExecutor? executor,
  }) async {
    await upsertAll(<BookSource>[source], executor: executor);
  }

  /// 观察全部书源；提交变化后重新按手动顺序查询。
  Stream<List<BookSource>> watchAll() async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.bookSources};
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

  /// 批量替换写入书源，用于导入事务。
  Future<void> upsertAll(
    List<BookSource> sources, {
    DatabaseExecutor? executor,
  }) async {
    if (sources.isEmpty) {
      return;
    }
    /// 当前写入使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'BATCH_INSERT_REPLACE',
      table: DatabaseTables.bookSources,
      itemCount: sources.length,
    );
    /// 将导入书源集中写入同一批次。
    final Batch batch = writeExecutor.batch();
    for (final BookSource source in sources) {
      batch.insert(
        DatabaseTables.bookSources,
        bookSourceToMap(source),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    if (executor == null) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.bookSources},
      );
    }
  }

  /// 原子累加成功率分值，不做读改写，避免搜索/详情/阅读并发写入时互相覆盖。
  Future<void> adjustScore(String sourceUrl, int delta) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.bookSources,
      where: 'bookSourceUrl = ? (sourceScore += $delta)',
      argumentCount: 2,
    );
    await database.rawUpdate(
      'UPDATE ${DatabaseTables.bookSources} SET sourceScore = sourceScore + ? WHERE bookSourceUrl = ?',
      <Object?>[delta, sourceUrl],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookSources});
  }

  /// 设置或取消书源置顶；低频用户操作，直接读改写整行。
  Future<void> setPinned(String sourceUrl, bool pinned) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 当前书源；不存在时忽略。
    final BookSource? source = await getByUrl(sourceUrl);
    if (source == null) {
      return;
    }
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.bookSources,
      where: 'bookSourceUrl = ? (pinned = $pinned)',
      argumentCount: 1,
    );
    await database.update(
      DatabaseTables.bookSources,
      <String, Object?>{'pinned': boolToSqlite(pinned)},
      where: 'bookSourceUrl = ?',
      whereArgs: <Object?>[sourceUrl],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookSources});
  }

  /// 按主键删除书源；外键会级联删除该书源的搜索缓存。
  Future<void> deleteByUrl(
    String sourceUrl, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前删除使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.bookSources,
      where: 'bookSourceUrl = ?',
      argumentCount: 1,
    );
    await writeExecutor.delete(
      DatabaseTables.bookSources,
      where: 'bookSourceUrl = ?',
      whereArgs: <Object?>[sourceUrl],
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.bookSources, DatabaseTables.searchBooks},
      );
    }
  }

  /// 批量删除指定 URL 书源。
  Future<void> deleteByUrls(
    Set<String> sourceUrls, {
    DatabaseExecutor? executor,
  }) async {
    if (sourceUrls.isEmpty) {
      return;
    }
    /// 当前删除使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor = executor ?? await _database.database;
    /// 参数化 IN 子句占位符。
    final String placeholders = List<String>.filled(sourceUrls.length, '?').join(',');
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.bookSources,
      where: 'bookSourceUrl IN ($placeholders)',
      argumentCount: sourceUrls.length,
    );
    await writeExecutor.delete(
      DatabaseTables.bookSources,
      where: 'bookSourceUrl IN ($placeholders)',
      whereArgs: sourceUrls.toList(growable: false),
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.bookSources, DatabaseTables.searchBooks},
      );
    }
  }
}
