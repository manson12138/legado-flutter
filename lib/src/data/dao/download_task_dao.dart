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
  Future<List<DownloadTask>> getByBook(int userId, String bookUrl) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.downloadTasks,
      where: 'userId = ? AND bookUrl = ? orderBy=chapterIndex ASC',
      argumentCount: 2,
    );
    /// 指定书籍的下载任务行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.downloadTasks,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
      orderBy: 'chapterIndex ASC',
    );
    return rows.map(downloadTaskFromMap).toList(growable: false);
  }

  /// 观察一本书的下载任务；任务表变化时重新查询。
  Stream<List<DownloadTask>> watchByBook(
    int userId,
    String bookUrl,
  ) async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.downloadTasks};
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(observedTables);
    while (true) {
      yield await getByBook(userId, bookUrl);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 读取一本书持久化的下载批次与自动换源状态。
  Future<DownloadBookState?> getBookState(
    int userId,
    String bookUrl,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.downloadBookStates,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    /// 指定书籍最多一条策略状态行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.downloadBookStates,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return downloadBookStateFromMap(rows.first);
  }

  /// 观察一本书的下载策略、锁定候选和批次评分状态。
  Stream<DownloadBookState?> watchBookState(
    int userId,
    String bookUrl,
  ) async* {
    /// 当前观察依赖的下载书籍状态表。
    final Set<String> observedTables = <String>{
      DatabaseTables.downloadBookStates,
    };
    /// 已消费的最近一次状态表提交版本。
    int observedRevision =
        _database.changeNotifier.revisionForTables(observedTables);
    while (true) {
      yield await getBookState(userId, bookUrl);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 写入一本书下载状态；同一书籍主键直接覆盖。
  Future<void> upsertBookState(
    int userId,
    DownloadBookState state,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.downloadBookStates,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.downloadBookStates,
      <String, Object?>{
        'userId': userId,
        ...downloadBookStateToMap(state),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(
      <String>{DatabaseTables.downloadBookStates},
    );
  }

  /// 观察全部书籍下载任务；任务表变化时按最近状态变化顺序重新查询。
  Stream<List<DownloadTask>> watchAll(int userId) async* {
    /// 当前观察依赖的下载任务表。
    final Set<String> observedTables = <String>{DatabaseTables.downloadTasks};
    /// 已消费的最近一次下载任务表提交版本。
    int observedRevision =
        _database.changeNotifier.revisionForTables(observedTables);
    while (true) {
      yield await getAll(userId);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 读取全部书籍下载任务，供跨书管理页汇总。
  Future<List<DownloadTask>> getAll(int userId) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.downloadTasks,
      where: 'userId = ? orderBy=updatedAt DESC',
      argumentCount: 1,
    );
    /// 全部下载任务行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.downloadTasks,
      where: 'userId = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'updatedAt DESC, bookUrl ASC, chapterIndex ASC',
    );
    return rows.map(downloadTaskFromMap).toList(growable: false);
  }

  /// 读取全部等待或运行中的任务；供调度器领取和应用重启后的崩溃恢复使用。
  Future<List<DownloadTask>> getPending(int userId) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.downloadTasks,
      where:
          'userId = ? AND status IN (waiting, running) '
          'orderBy=updatedAt ASC',
      argumentCount: 1,
    );
    /// 全部等待或运行中的任务行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.downloadTasks,
      where: 'userId = ? AND status IN (?, ?)',
      whereArgs: <Object?>[
        userId,
        DownloadTaskStatus.waiting.name,
        DownloadTaskStatus.running.name,
      ],
      orderBy: 'updatedAt ASC',
    );
    return rows.map(downloadTaskFromMap).toList(growable: false);
  }

  /// 批量写入任务；已存在的 `(bookUrl, chapterIndex)` 直接覆盖。
  Future<void> upsertAll(int userId, List<DownloadTask> tasks) async {
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
        <String, Object?>{'userId': userId, ...downloadTaskToMap(task)},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 写入单个任务；已存在的 `(bookUrl, chapterIndex)` 直接覆盖。
  Future<void> upsert(int userId, DownloadTask task) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.downloadTasks,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.downloadTasks,
      <String, Object?>{'userId': userId, ...downloadTaskToMap(task)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 删除单个任务。
  Future<void> deleteTask(
    int userId,
    String bookUrl,
    int chapterIndex,
  ) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.downloadTasks,
      where: 'userId = ? AND bookUrl = ? AND chapterIndex = ?',
      argumentCount: 3,
    );
    await database.delete(
      DatabaseTables.downloadTasks,
      where: 'userId = ? AND bookUrl = ? AND chapterIndex = ?',
      whereArgs: <Object?>[userId, bookUrl, chapterIndex],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 删除一本书的全部下载任务。
  Future<void> deleteByBook(int userId, String bookUrl) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.downloadTasks,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    await database.delete(
      DatabaseTables.downloadTasks,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
    );
    _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
  }

  /// 把全部残留“运行中”任务重置为“等待”；应用重启后旧运行状态已不可信。
  Future<int> resetRunningToWaiting(int userId, int now) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.downloadTasks,
      where: 'userId = ? AND status = running',
      argumentCount: 1,
    );
    /// 被重置的任务行数。
    final int count = await database.update(
      DatabaseTables.downloadTasks,
      <String, Object?>{'status': DownloadTaskStatus.waiting.name, 'updatedAt': now},
      where: 'userId = ? AND status = ?',
      whereArgs: <Object?>[userId, DownloadTaskStatus.running.name],
    );
    if (count > 0) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.downloadTasks});
    }
    return count;
  }

  /// 暂停全部等待或运行任务。
  Future<int> pauseAll(int userId, int now) {
    return _replaceStatuses(
      from: const <DownloadTaskStatus>{
        DownloadTaskStatus.waiting,
        DownloadTaskStatus.running,
      },
      to: DownloadTaskStatus.paused,
      now: now,
      userId: userId,
    );
  }

  /// 暂停一本书的等待或运行任务。
  Future<int> pauseBook(int userId, String bookUrl, int now) {
    return _replaceStatuses(
      from: const <DownloadTaskStatus>{
        DownloadTaskStatus.waiting,
        DownloadTaskStatus.running,
      },
      to: DownloadTaskStatus.paused,
      now: now,
      userId: userId,
      bookUrl: bookUrl,
    );
  }

  /// 暂停指定章节的等待或运行任务。
  Future<int> pauseTask(
    int userId,
    String bookUrl,
    int chapterIndex,
    int now,
  ) {
    return _replaceStatuses(
      from: const <DownloadTaskStatus>{
        DownloadTaskStatus.waiting,
        DownloadTaskStatus.running,
      },
      to: DownloadTaskStatus.paused,
      now: now,
      userId: userId,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
    );
  }

  /// 恢复全部暂停任务为等待状态。
  Future<int> resumeAll(int userId, int now) {
    return _replaceStatuses(
      from: const <DownloadTaskStatus>{DownloadTaskStatus.paused},
      to: DownloadTaskStatus.waiting,
      now: now,
      userId: userId,
    );
  }

  /// 恢复一本书的全部暂停任务为等待状态。
  Future<int> resumeBook(int userId, String bookUrl, int now) {
    return _replaceStatuses(
      from: const <DownloadTaskStatus>{DownloadTaskStatus.paused},
      to: DownloadTaskStatus.waiting,
      now: now,
      userId: userId,
      bookUrl: bookUrl,
    );
  }

  /// 按可选书籍和章节范围批量替换任务状态，并只在真实变化后通知观察流。
  Future<int> _replaceStatuses({
    required int userId,
    required Set<DownloadTaskStatus> from,
    required DownloadTaskStatus to,
    required int now,
    String? bookUrl,
    int? chapterIndex,
  }) async {
    /// 已打开的数据库连接。
    final Database database = await _database.database;
    /// 原状态集合对应的 SQL 占位符。
    final String statusPlaceholders =
        List<String>.filled(from.length, '?').join(',');
    /// 最终更新条件片段。
    final List<String> whereParts = <String>[
      'userId = ?',
      'status IN ($statusPlaceholders)',
    ];
    /// 最终更新条件参数。
    final List<Object?> whereArgs = <Object?>[
      userId,
      ...from.map((DownloadTaskStatus status) => status.name),
    ];
    if (bookUrl != null) {
      whereParts.add('bookUrl = ?');
      whereArgs.add(bookUrl);
    }
    if (chapterIndex != null) {
      whereParts.add('chapterIndex = ?');
      whereArgs.add(chapterIndex);
    }
    _database.logOperation(
      operation: 'UPDATE_STATUS',
      table: DatabaseTables.downloadTasks,
      where: whereParts.join(' AND '),
      argumentCount: whereArgs.length,
    );
    /// 被本次状态替换命中的任务数量。
    final int count = await database.update(
      DatabaseTables.downloadTasks,
      <String, Object?>{
        'status': to.name,
        'updatedAt': now,
      },
      where: whereParts.join(' AND '),
      whereArgs: whereArgs,
    );
    if (count > 0) {
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.downloadTasks},
      );
    }
    return count;
  }
}
