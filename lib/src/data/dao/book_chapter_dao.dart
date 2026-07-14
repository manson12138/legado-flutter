import 'package:sqflite/sqflite.dart';

import '../../domain/model/book_chapter.dart';
import '../local/database_tables.dart';
import '../local/entity_maps.dart';
import '../local/legado_database.dart';

/// 只负责 `chapters` 表查询和写入，对应 Android `BookChapterDao`。
final class BookChapterDao {
  /// 创建章节 DAO。
  const BookChapterDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按章节索引升序读取一本书的完整目录。
  Future<List<BookChapter>> getChapterList(
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    /// 指定书籍的章节行。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.chapters,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
      orderBy: '`index` ASC',
    );
    return rows.map(bookChapterFromMap).toList(growable: false);
  }

  /// 按书籍 URL 和章节索引读取单章。
  Future<BookChapter?> getChapter(
    String bookUrl,
    int index, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或事务执行器。
    final DatabaseExecutor queryExecutor =
        executor ?? await _database.database;
    /// 最多包含一章的索引查询结果。
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.chapters,
      where: 'bookUrl = ? AND `index` = ?',
      whereArgs: <Object?>[bookUrl, index],
      limit: 1,
    );
    return rows.isEmpty ? null : bookChapterFromMap(rows.first);
  }

  /// 观察一本书的目录；章节表变化后重新读取并按索引排序。
  Stream<List<BookChapter>> watchChapterList(String bookUrl) async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{DatabaseTables.chapters};
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(
      observedTables,
    );
    while (true) {
      yield await getChapterList(bookUrl);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 批量替换写入章节；调用方可传入事务以和书籍写入组成闭环。
  Future<void> upsertAll(
    List<BookChapter> chapters, {
    DatabaseExecutor? executor,
  }) async {
    if (chapters.isEmpty) {
      return;
    }
    /// 当前写入使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    /// 将所有章节写入同一批次，保持顺序和约束检查集中执行。
    final Batch batch = writeExecutor.batch();
    for (final BookChapter chapter in chapters) {
      batch.insert(
        DatabaseTables.chapters,
        bookChapterToMap(chapter),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    if (executor == null) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.chapters});
    }
  }

  /// 删除一本书的全部章节；用于目录整体替换。
  Future<void> deleteByBook(
    String bookUrl, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前删除使用的数据库或事务执行器。
    final DatabaseExecutor writeExecutor =
        executor ?? await _database.database;
    await writeExecutor.delete(
      DatabaseTables.chapters,
      where: 'bookUrl = ?',
      whereArgs: <Object?>[bookUrl],
    );
    if (executor == null) {
      _database.changeNotifier.notifyTables(<String>{DatabaseTables.chapters});
    }
  }
}
