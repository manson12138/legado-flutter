import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../domain/model/toc_refresh_checkpoint.dart';
import '../local/database_tables.dart';
import '../local/legado_database.dart';

/// 读写用户级目录增量更新检查点；页面和业务 ViewModel 不直接访问本 DAO。
final class TocRefreshCheckpointDao {
  /// 防止损坏行把异常大的 JSON 集合带入目录分页；同时允许长篇连载跨多次增量增长。
  static const int _maximumVisitedPageCount = 512;

  /// 创建绑定独立 SQLite 数据库的检查点 DAO。
  const TocRefreshCheckpointDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按用户和书籍主键读取一条检查点；损坏行按不存在处理并触发完整刷新。
  Future<TocRefreshCheckpoint?> get(int userId, String bookUrl) async {
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.tocRefreshCheckpoints,
      where: 'userId = ? AND bookUrl = ? limit=1',
      argumentCount: 2,
    );
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.tocRefreshCheckpoints,
      where: 'userId = ? AND bookUrl = ?',
      whereArgs: <Object?>[userId, bookUrl],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _fromMap(rows.first);
  }

  /// 插入或覆盖一次成功更新得到的检查点。
  Future<void> upsert(int userId, TocRefreshCheckpoint checkpoint) async {
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.tocRefreshCheckpoints,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.tocRefreshCheckpoints,
      <String, Object?>{
        'userId': userId,
        'bookUrl': checkpoint.bookUrl,
        'sourceUrl': checkpoint.sourceUrl,
        'tocUrl': checkpoint.tocUrl,
        'anchorPageUrl': checkpoint.anchorPageUrl,
        'visitedPageUrlsJson': jsonEncode(checkpoint.visitedPageUrls),
        'anchorChapterUrl': checkpoint.anchorChapterUrl,
        'reverse': checkpoint.reverse ? 1 : 0,
        'chapterCount': checkpoint.chapterCount,
        'lastSuccessfulAt': checkpoint.lastSuccessfulAt,
        'lastFullRefreshAt': checkpoint.lastFullRefreshAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除当前用户已不在书架或历史中的孤立检查点。
  Future<void> deleteBooksNotIn(int userId, Set<String> activeBookUrls) async {
    final Database database = await _database.database;
    if (activeBookUrls.isEmpty) {
      _database.logOperation(
        operation: 'DELETE',
        table: DatabaseTables.tocRefreshCheckpoints,
        where: 'userId = ?',
        argumentCount: 1,
      );
      await database.delete(
        DatabaseTables.tocRefreshCheckpoints,
        where: 'userId = ?',
        whereArgs: <Object?>[userId],
      );
      return;
    }
    final String placeholders =
        List<String>.filled(activeBookUrls.length, '?').join(',');
    _database.logOperation(
      operation: 'DELETE',
      table: DatabaseTables.tocRefreshCheckpoints,
      where: 'userId = ? AND bookUrl NOT IN (...)',
      argumentCount: activeBookUrls.length + 1,
    );
    await database.delete(
      DatabaseTables.tocRefreshCheckpoints,
      where: 'userId = ? AND bookUrl NOT IN ($placeholders)',
      whereArgs: <Object?>[userId, ...activeBookUrls],
    );
  }

  /// 将未经信任的 SQLite 行转换为检查点；任何非法字段都使整行失效。
  TocRefreshCheckpoint? _fromMap(Map<String, Object?> row) {
    final Object? bookUrlValue = row['bookUrl'];
    final Object? sourceUrlValue = row['sourceUrl'];
    final Object? tocUrlValue = row['tocUrl'];
    final Object? anchorPageUrlValue = row['anchorPageUrl'];
    final Object? visitedPageUrlsJsonValue = row['visitedPageUrlsJson'];
    final Object? anchorChapterUrlValue = row['anchorChapterUrl'];
    final Object? reverseValue = row['reverse'];
    final Object? chapterCountValue = row['chapterCount'];
    final Object? lastSuccessfulAtValue = row['lastSuccessfulAt'];
    final Object? lastFullRefreshAtValue = row['lastFullRefreshAt'];
    final List<String>? visitedPageUrls =
        _decodeVisitedPageUrls(visitedPageUrlsJsonValue);
    if (bookUrlValue is! String ||
        bookUrlValue.isEmpty ||
        sourceUrlValue is! String ||
        sourceUrlValue.isEmpty ||
        tocUrlValue is! String ||
        tocUrlValue.isEmpty ||
        anchorPageUrlValue is! String ||
        anchorPageUrlValue.isEmpty ||
        visitedPageUrls == null ||
        visitedPageUrls.isEmpty ||
        anchorChapterUrlValue is! String ||
        anchorChapterUrlValue.isEmpty ||
        reverseValue is! int ||
        (reverseValue != 0 && reverseValue != 1) ||
        chapterCountValue is! int ||
        chapterCountValue <= 0 ||
        lastSuccessfulAtValue is! int ||
        lastSuccessfulAtValue <= 0 ||
        lastFullRefreshAtValue is! int ||
        lastFullRefreshAtValue <= 0) {
      return null;
    }
    return TocRefreshCheckpoint(
      bookUrl: bookUrlValue,
      sourceUrl: sourceUrlValue,
      tocUrl: tocUrlValue,
      anchorPageUrl: anchorPageUrlValue,
      visitedPageUrls: visitedPageUrls,
      anchorChapterUrl: anchorChapterUrlValue,
      reverse: reverseValue == 1,
      chapterCount: chapterCountValue,
      lastSuccessfulAt: lastSuccessfulAtValue,
      lastFullRefreshAt: lastFullRefreshAtValue,
    );
  }

  /// 解码有界的非空分页地址；非法或损坏 JSON 使检查点整体失效。
  List<String>? _decodeVisitedPageUrls(Object? rawValue) {
    if (rawValue is! String || rawValue.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(rawValue);
      if (decoded is! List<Object?> ||
          decoded.isEmpty ||
          decoded.length > _maximumVisitedPageCount) {
        return null;
      }
      final List<String> urls = <String>[];
      for (final Object? value in decoded) {
        if (value is! String || value.isEmpty) {
          return null;
        }
        urls.add(value);
      }
      return List<String>.unmodifiable(urls);
    } on FormatException {
      return null;
    }
  }
}
