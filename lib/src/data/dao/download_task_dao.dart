import 'package:sqflite/sqflite.dart';

import '../../domain/model/download_task.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `download_tasks` 表查询和写入；Flutter 新增表，Android 无对应持久实体。
final class DownloadTaskDao {
  /// 创建离线下载任务 DAO。
  const DownloadTaskDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按章节索引升序读取一本书的全部下载任务。
  Future<List<DownloadTask>> getByBook(String bookUrl) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.downloadTasks,
      where: 'bookUrl = ? orderBy=chapterIndex ASC',
      argumentCount: 1,
    );
    /// 指定书籍的下载任务行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.downloadTasks,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
      orderBy: 'chapterIndex ASC',
    );
    return rows.map(downloadTaskFromMap).toList(growable: false);
  }

  /// 观察一本书的下载任务；任务表变化时重新查询。
  Stream<List<DownloadTask>> watchByBook(String bookUrl) async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.downloadTasks};
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(observedTables);
    while (true) {
      yield await getByBook(bookUrl);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 读取全部等待或运行中的任务；供调度器领取和应用重启后的崩溃恢复使用。
  Future<List<DownloadTask>> getPending() async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.downloadTasks,
      where: 'status IN (waiting, running) orderBy=updatedAt ASC',
    );
    /// 全部等待或运行中的任务行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.downloadTasks,
      where: 'status IN (?, ?)',
      whereArgs: <Object?>[DownloadTaskStatus.waiting.name, DownloadTaskStatus.running.name],
      orderBy: 'updatedAt ASC',
    );
    return rows.map(downloadTaskFromMap).toList(growable: false);
  }

  /// 批量写入任务；已存在的 `(bookUrl, chapterIndex)` 直接覆盖。
  Future<void> upsertAll(List<DownloadTask> tasks) async {
    if (tasks.isEmpty) {
      return;
    }
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'BATCH_INSERT_REPLACE',
      table: DatabaseTables.downloadTasks,
      itemCount: tasks.length,
    );
    /// 将所有任务写入同一批次。
    final Batch batch = database.batch();
    for (final DownloadTask task in tasks) {
      batch.insert(
        DatabaseTables.downloadTasks,
        downloadTaskToMap(task),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 写入单个任务；已存在的 `(bookUrl, chapterIndex)` 直接覆盖。
  Future<void> upsert(DownloadTask task) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.downloadTasks,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.downloadTasks,
      downloadTaskToMap(task),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 删除单个任务。
  Future<void> deleteTask(String bookUrl, int chapterIndex) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.downloadTasks,
      where: 'bookUrl = ? AND chapterIndex = ?',
      argumentCount: 2,
    );
    await database.delete(
      DatabaseTables.downloadTasks,
      where: 'bookUrl = ? AND chapterIndex = ?',
      whereArgs: <Object?>[bookUrl, chapterIndex],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 删除一本书的全部下载任务。
  Future<void> deleteByBook(String bookUrl) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.downloadTasks,
      where: 'bookUrl = ?',
      argumentCount: 1,
    );
    await database.delete(
      DatabaseTables.downloadTasks,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 把全部残留“运行中”任务重置为“等待”；应用重启后旧运行状态已不可信。
  Future<int> resetRunningToWaiting(int now) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.downloadTasks,
      where: 'status = running',
    );
    /// 被重置的任务行数。
    final int count = await database.update(
      DatabaseTables.downloadTasks,
      <String, Object?>{'status': DownloadTaskStatus.waiting.name, 'updatedAt': now},
      where: 'status = ?',
      whereArgs: <Object?>[DownloadTaskStatus.running.name],
    );
    if (count > 0) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
    }
    return count;
  }
}
