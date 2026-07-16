import 'package:sqflite/sqflite.dart';

import '../../domain/model/replace_rule.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `replace_rules` 表查询和写入，对应 Android `ReplaceRuleDao` 的核心能力。
final class ReplaceRuleDao {
  /// 创建净化规则 DAO。
  const ReplaceRuleDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按手动顺序读取全部替换规则。
  Future<List<ReplaceRule>> getAll() async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.replaceRules,
      where: '<all> orderBy=sortOrder ASC',
    );
    /// 全部净化规则数据库行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.replaceRules,
      orderBy: 'sortOrder ASC',
    );
    return rows.map(replaceRuleFromMap).toList(growable: false);
  }

  /// 查询适用于指定书名或书源的已启用正文规则。
  Future<List<ReplaceRule>> getEnabledForContent(
    String bookName,
    String origin,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.replaceRules,
      where: 'enabled content scope query orderBy=sortOrder ASC',
      argumentCount: 4,
    );
    /// 与 Android `findEnabledByContentScope` 等价的规则行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.replaceRules,
      where: '''
        isEnabled = 1 AND scopeContent = 1
        AND (scope LIKE ? OR scope LIKE ? OR scope IS NULL OR scope = '')
        AND (
          excludeScope IS NULL
          OR (excludeScope NOT LIKE ? AND excludeScope NOT LIKE ?)
        )
      ''',
      whereArgs: <Object?>[
        '%$bookName%',
        '%$origin%',
        '%$bookName%',
        '%$origin%',
      ],
      orderBy: 'sortOrder ASC',
    );
    return rows.map(replaceRuleFromMap).toList(growable: false);
  }

  /// 观察全部净化规则；表变化时重新查询。
  Stream<List<ReplaceRule>> watchAll() async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.replaceRules};
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

  /// 插入或替换净化规则，并返回数据库主键。
  Future<int> upsert(ReplaceRule rule) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.replaceRules,
      itemCount: 1,
    );
    /// SQLite 返回的自增或既有规则主键。
    final int id = await database.insert(
      DatabaseTables.replaceRules,
      replaceRuleToMap(rule),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.replaceRules});
    return id;
  }

  /// 按数据库主键删除净化规则。
  Future<void> deleteById(int id) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.replaceRules,
      where: 'id = ?',
      argumentCount: 1,
    );
    await database.delete(
      DatabaseTables.replaceRules,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.replaceRules});
  }
}
