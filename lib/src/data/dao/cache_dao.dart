import 'package:sqflite/sqflite.dart';

import '../../domain/model/cache.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `caches` 表查询、有效期判断和写入，对应 Android `CacheDao`。
final class CacheDao {
  /// 创建缓存 DAO。
  const CacheDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按缓存键读取完整记录，不自动忽略过期值。
  Future<Cache?> get(String key) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 最多包含一条缓存的查询结果。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.caches,
      where: '`key` = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : cacheFromMap(rows.first);
  }

  /// 只读取未过期缓存值；[now] 为 Unix Epoch 毫秒。
  Future<String?> getValidValue(String key, int now) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 最多包含一个有效缓存值的查询结果。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.caches,
      columns: <String>['value'],
      where: '`key` = ? AND (deadline = 0 OR deadline > ?)',
      whereArgs: <Object?>[key, now],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    /// 有效缓存行的原始 value 字段。
    final Object? value = rows.first['value'];
    if (value == null || value is String) {
      return value as String?;
    }
    throw const FormatException('数据库列 value 不是可空字符串');
  }

  /// 以缓存键替换写入记录。
  Future<void> upsert(Cache cache) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    await database.insert(
      DatabaseTables.caches,
      cacheToMap(cache),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.caches});
  }

  /// 删除所有已经过期且设置了有效期的缓存；[now] 为 Unix Epoch 毫秒。
  Future<void> clearExpired(int now) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    await database.delete(
      DatabaseTables.caches,
      where: 'deadline > 0 AND deadline < ?',
      whereArgs: <Object?>[now],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.caches});
  }

  /// 按缓存键删除记录。
  Future<void> delete(String key) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    await database.delete(
      DatabaseTables.caches,
      where: '`key` = ?',
      whereArgs: <Object?>[key],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.caches});
  }
}
