import 'package:sqflite/sqflite.dart';

import '../../domain/model/cookie.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `cookies` 表查询和写入，对应 Android `CookieDao`。
final class CookieDao {
  /// 创建 Cookie DAO。
  const CookieDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按 Cookie 作用域键读取记录。
  Future<Cookie?> get(String url) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.cookies,
      where: 'url = ? limit=1',
      argumentCount: 1,
    );
    /// 最多包含一条 Cookie 的查询结果。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.cookies,
      where: 'url = ?',
      whereArgs: <Object?>[url],
      limit: 1,
    );
    return rows.isEmpty ? null : cookieFromMap(rows.first);
  }

  /// 以 URL 主键替换写入 Cookie；调用方不得记录 [cookie] 内容。
  Future<void> upsert(Cookie cookie) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.cookies,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.cookies,
      cookieToMap(cookie),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.cookies});
  }

  /// 按 URL 主键删除 Cookie。
  Future<void> delete(String url) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.cookies,
      where: 'url = ?',
      argumentCount: 1,
    );
    await database.delete(
      DatabaseTables.cookies,
      where: 'url = ?',
      whereArgs: <Object?>[url],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.cookies});
  }
}
