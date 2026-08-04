import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../domain/model/book_content_process.dart';
import '../local/database_tables.dart';
import '../local/legado_database.dart';
import '../local/sqlite_row_reader.dart';

/// 只负责 `book_content_processes` 表读写，对应 Android `BookContentProcessDao`。
final class BookContentProcessDao {
  /// 创建正文标注 DAO。
  const BookContentProcessDao(this._database);

  /// Flutter 独立数据库入口。
  final LegadoDatabase _database;

  /// 按创建顺序读取指定章节全部未软删除标注。
  Future<List<BookContentProcess>> getForChapter(
    int userId,
    String bookUrl,
    int chapterIndex,
  ) async {
    /// 已打开的共享数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND bookUrl = ? AND chapterIndex = ? AND status != 3',
      argumentCount: 3,
    );
    /// 当前章节按稳定顺序读取的数据库行。
    final List<Map<String, Object?>> rows = await database.query(
      DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND bookUrl = ? AND chapterIndex = ? AND status != ?',
      whereArgs: <Object?>[
        userId,
        bookUrl,
        chapterIndex,
        BookContentProcess.deletedStatus,
      ],
      orderBy: 'sortOrder ASC, createdAt ASC',
    );
    return rows.map(_fromMap).toList(growable: false);
  }

  /// 观察指定章节标注；相关表提交后重新查询。
  Stream<List<BookContentProcess>> watchForChapter(
    int userId,
    String bookUrl,
    int chapterIndex,
  ) async* {
    /// 当前观察依赖的表集合。
    final Set<String> observedTables = <String>{
      DatabaseTables.bookContentProcesses,
    };
    /// 已消费的最近一次相关表提交版本。
    int observedRevision = _database.changeNotifier.revisionForTables(
      observedTables,
    );
    while (true) {
      yield await getForChapter(userId, bookUrl, chapterIndex);
      observedRevision = await _database.changeNotifier.waitForTableChange(
        observedTables,
        observedRevision,
      );
    }
  }

  /// 读取同一本书当前最大的标注排序值。
  Future<int> maxOrder(int userId, String bookUrl) async {
    /// 已打开的共享数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SELECT_MAX',
      table: DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND bookUrl = ?',
      argumentCount: 2,
    );
    /// SQLite 聚合查询结果。
    final List<Map<String, Object?>> rows = await database.rawQuery(
      'SELECT COALESCE(MAX(sortOrder), 0) AS maxOrder '
      'FROM ${DatabaseTables.bookContentProcesses} '
      'WHERE userId = ? AND bookUrl = ?',
      <Object?>[userId, bookUrl],
    );
    if (rows.isEmpty) {
      return 0;
    }
    /// 聚合结果中的不可信最大值。
    final Object? value = rows.first['maxOrder'];
    return value is int ? value : 0;
  }

  /// 以稳定主键新增或替换一条正文标注。
  Future<void> upsert(int userId, BookContentProcess process) async {
    /// 已打开的共享数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'INSERT_REPLACE',
      table: DatabaseTables.bookContentProcesses,
      itemCount: 1,
    );
    await database.insert(
      DatabaseTables.bookContentProcesses,
      <String, Object?>{'userId': userId, ..._toMap(process)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _database.changeNotifier.notifyTables(
      <String>{DatabaseTables.bookContentProcesses},
    );
  }

  /// 更新一条标注的启用状态。
  Future<void> setEnabled(
    int userId,
    String id,
    bool enabled,
    int updatedAt,
  ) async {
    /// 已打开的共享数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'UPDATE',
      table: DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND id = ?',
      argumentCount: 2,
    );
    await database.update(
      DatabaseTables.bookContentProcesses,
      <String, Object?>{
        'enabled': enabled ? 1 : 0,
        'updatedAt': updatedAt,
      },
      where: 'userId = ? AND id = ?',
      whereArgs: <Object?>[userId, id],
    );
    _database.changeNotifier.notifyTables(
      <String>{DatabaseTables.bookContentProcesses},
    );
  }

  /// 将一条标注软删除，保留同步和冲突处理所需事实。
  Future<void> markDeleted(int userId, String id, int updatedAt) async {
    /// 已打开的共享数据库连接。
    final Database database = await _database.database;
    _database.logOperation(
      operation: 'SOFT_DELETE',
      table: DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND id = ?',
      argumentCount: 2,
    );
    await database.update(
      DatabaseTables.bookContentProcesses,
      <String, Object?>{
        'status': BookContentProcess.deletedStatus,
        'updatedAt': updatedAt,
      },
      where: 'userId = ? AND id = ?',
      whereArgs: <Object?>[userId, id],
    );
    _database.changeNotifier.notifyTables(
      <String>{DatabaseTables.bookContentProcesses},
    );
  }

  /// 读取当前账号全部未软删除用户标注，供逻辑备份导出使用。
  Future<List<BookContentProcess>> getAllActive(
    int userId, {
    DatabaseExecutor? executor,
  }) async {
    /// 当前查询使用的数据库或备份只读事务。
    final DatabaseExecutor queryExecutor = executor ?? await _database.database;
    _database.logOperation(
      operation: 'SELECT',
      table: DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND status != 3 orderBy=createdAt ASC',
      argumentCount: 2,
    );
    final List<Map<String, Object?>> rows = await queryExecutor.query(
      DatabaseTables.bookContentProcesses,
      where: 'userId = ? AND status != ?',
      whereArgs: <Object?>[userId, BookContentProcess.deletedStatus],
      orderBy: 'createdAt ASC',
    );
    return rows.map(_fromMap).toList(growable: false);
  }

  /// 把领域正文标注转换为 Android 兼容数据库列。
  Map<String, Object?> _toMap(BookContentProcess process) {
    return <String, Object?>{
      'id': process.id,
      'bookUrl': process.bookUrl,
      'chapterIndex': process.chapterIndex,
      'kind': process.kind.storageName,
      'stage': 'style',
      'target': 'selection',
      'anchorJson': jsonEncode(<String, Object?>{
        'chapterIndex': process.anchor.chapterIndex,
        'chapterPosition': process.anchor.chapterPosition,
        'selectedText': process.anchor.selectedText,
        'contextBefore': process.anchor.contextBefore,
        'contextAfter': process.anchor.contextAfter,
        'normalizedTextHash': process.anchor.normalizedTextHash,
      }),
      'actionJson': jsonEncode(<String, Object?>{'type': 'style'}),
      'styleJson': jsonEncode(<String, Object?>{
        'bgColor': process.style.backgroundColorValue,
        'underlineColor': process.style.underlineColorValue,
        'underlineWidth': process.style.underlineWidth,
      }),
      'source': 'user',
      'aiArtifactId': null,
      'sourceContentHash': null,
      'enabled': process.enabled ? 1 : 0,
      'sortOrder': process.sortOrder,
      'status': process.status,
      'schemaVersion': 1,
      'createdAt': process.createdAt,
      'updatedAt': process.updatedAt,
    };
  }

  /// 从不可信数据库行恢复受支持的用户正文标注。
  BookContentProcess _fromMap(Map<String, Object?> row) {
    /// 对当前正文标注行执行安全类型读取的解析器。
    final SqliteRowReader reader = SqliteRowReader(row);
    /// 数据库持久化的用户标注类型。
    final BookContentProcessKind? kind =
        BookContentProcessKindStorage.fromStorageName(
      reader.requiredString('kind'),
    );
    if (kind == null) {
      throw const FormatException('正文标注类型不受支持');
    }
    /// 解码后的锚点 JSON 根值。
    final Object? anchorValue = jsonDecode(reader.requiredString('anchorJson'));
    /// 解码后的样式 JSON 根值。
    final Object? styleValue = jsonDecode(reader.nullableString('styleJson') ?? '{}');
    if (anchorValue is! Map<String, Object?> ||
        styleValue is! Map<String, Object?>) {
      throw const FormatException('正文标注 JSON 结构无效');
    }
    /// 锚点章节索引。
    final Object? anchorChapterIndex = anchorValue['chapterIndex'];
    /// 锚点字符位置。
    final Object? chapterPosition = anchorValue['chapterPosition'];
    /// 锚点选区原文。
    final Object? selectedText = anchorValue['selectedText'];
    /// 锚点规范化摘要。
    final Object? normalizedTextHash = anchorValue['normalizedTextHash'];
    if (anchorChapterIndex is! int ||
        chapterPosition is! int ||
        selectedText is! String ||
        normalizedTextHash is! String) {
      throw const FormatException('正文标注锚点字段无效');
    }
    return BookContentProcess(
      id: reader.requiredString('id'),
      bookUrl: reader.requiredString('bookUrl'),
      chapterIndex: reader.requiredInt('chapterIndex'),
      kind: kind,
      anchor: TextProcessAnchor(
        chapterIndex: anchorChapterIndex,
        chapterPosition: chapterPosition,
        selectedText: selectedText,
        contextBefore: anchorValue['contextBefore'] is String
            ? anchorValue['contextBefore'] as String
            : '',
        contextAfter: anchorValue['contextAfter'] is String
            ? anchorValue['contextAfter'] as String
            : '',
        normalizedTextHash: normalizedTextHash,
      ),
      style: TextProcessStyle(
        backgroundColorValue: styleValue['bgColor'] is int
            ? styleValue['bgColor'] as int
            : null,
        underlineColorValue: styleValue['underlineColor'] is int
            ? styleValue['underlineColor'] as int
            : null,
        underlineWidth: styleValue['underlineWidth'] is num
            ? (styleValue['underlineWidth'] as num).toDouble()
            : 1,
      ),
      enabled: reader.requiredBool('enabled'),
      sortOrder: reader.requiredInt('sortOrder'),
      status: reader.requiredInt('status'),
      createdAt: reader.requiredInt('createdAt'),
      updatedAt: reader.requiredInt('updatedAt'),
    );
  }
}
