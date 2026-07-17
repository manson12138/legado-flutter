import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/book_source_import_result.dart';
import '../../domain/model/cache.dart';
import '../../help/error/app_error.dart';
import '../dao/book_source_dao.dart';
import '../dao/cache_dao.dart';
import '../local/data_error.dart';
import '../local/database_tables.dart';
import '../local/legado_database.dart';
import '../model/book_source_import_decoder.dart';

/// 使用 SQLite 实现书源领域边界，并统一转换底层错误。
final class BookSourceRepository implements BookSourceGateway {
  /// 创建书源 Repository。
  const BookSourceRepository(
    this._database,
    this._bookSourceDao,
    this._cacheDao,
    this._importDecoder,
  );

  /// 用于导入事务和提交后通知的数据库入口。
  final LegadoDatabase _database;
  /// 只包含书源表查询和写入的 DAO。
  final BookSourceDao _bookSourceDao;
  /// 保存书源运行变量的通用缓存 DAO，不向 UI 暴露数据库实现。
  final CacheDao _cacheDao;
  /// 隔离外部 JSON 和持久化实体的书源解码器。
  final BookSourceImportDecoder _importDecoder;

  /// 观察全部书源，不向上层暴露 sqflite 流或行对象。
  @override
  Stream<List<BookSource>> watchAll() {
    return guardDataStream<List<BookSource>>(_bookSourceDao.watchAll());
  }

  /// 一次性读取全部书源，供启动默认数据导入等非观察场景使用。
  @override
  Future<List<BookSource>> getAll() {
    return guardDataOperation<List<BookSource>>(_bookSourceDao.getAll);
  }

  /// 按书源 URL 查询并转换数据错误。
  @override
  Future<BookSource?> getByUrl(String sourceUrl) {
    return guardDataOperation<BookSource?>(
      () => _bookSourceDao.getByUrl(sourceUrl),
    );
  }

  /// 读取当前启用书源，保持 DAO 排序语义。
  @override
  Future<List<BookSource>> getEnabled() {
    return guardDataOperation<List<BookSource>>(_bookSourceDao.getEnabled);
  }

  /// 在单一事务中替换导入全部书源，任一约束失败则整体回滚。
  @override
  Future<int> importSources(List<BookSource> sources) {
    return guardDataOperation<int>(() async {
      await _database.transaction<void>((transaction) async {
        await _bookSourceDao.upsertAll(sources, executor: transaction);
      });
      if (sources.isNotEmpty) {
        _database.changeNotifier.notifyTables(
          <String>{DatabaseTables.bookSources},
        );
      }
      return sources.length;
    });
  }

  /// 先在数据库边界外完成不可信 JSON 类型收窄，再执行原子导入。
  @override
  Future<BookSourceImportResult> importSourceJson(
    String sourceJson, {
    required BookSourceConflictPolicy conflictPolicy,
  }) async {
    try {
      /// 完成历史字段兼容和逐条必填字段校验的批次。
      final DecodedBookSourceBatch batch = _importDecoder.decodeBatch(sourceJson);
      return await guardDataOperation<BookSourceImportResult>(() async {
        /// 新增书源数量。
        int added = 0;
        /// 覆盖书源数量。
        int overwritten = 0;
        /// 跳过书源数量。
        int skipped = 0;
        await _database.transaction<void>((transaction) async {
          /// 同批已经处理的 URL，重复记录只采用首条。
          final Set<String> seenUrls = <String>{};
          for (final BookSource source in batch.sources) {
            if (!seenUrls.add(source.bookSourceUrl)) {
              skipped += 1;
              continue;
            }
            /// 当前数据库中的同 URL 书源。
            final BookSource? existing = await _bookSourceDao.getByUrl(
              source.bookSourceUrl,
              executor: transaction,
            );
            if (existing != null && conflictPolicy == BookSourceConflictPolicy.skip) {
              skipped += 1;
              continue;
            }
            await _bookSourceDao.upsert(source, executor: transaction);
            if (existing == null) {
              added += 1;
            } else {
              overwritten += 1;
            }
          }
        });
        if (added + overwritten > 0) {
          _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookSources});
        }
        return BookSourceImportResult(
          total: batch.total,
          added: added,
          overwritten: overwritten,
          skipped: skipped,
          invalid: batch.issues.length,
          issues: batch.issues,
        );
      });
    } on FormatException catch (error, stackTrace) {
      throw AppError(
        kind: AppErrorKind.validation,
        message: '书源 JSON 格式无效',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 保存单个编辑结果，并在主键变化时原子删除旧记录。
  @override
  Future<void> saveSource(BookSource source, {String? previousUrl}) {
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        if (previousUrl != null && previousUrl != source.bookSourceUrl) {
          await _bookSourceDao.deleteByUrl(previousUrl, executor: transaction);
        }
        await _bookSourceDao.upsert(source, executor: transaction);
      });
      _database.changeNotifier.notifyTables(
        <String>{DatabaseTables.bookSources, DatabaseTables.searchBooks},
      );
    });
  }

  /// 读取 Flutter 独立缓存中的书源自定义变量。
  @override
  Future<String> getSourceVariable(String sourceUrl) {
    return guardDataOperation<String>(() async {
      /// 当前未过期的书源变量；不存在时对齐 Android 返回空字符串。
      final String? value = await _cacheDao.getValidValue(
        _sourceVariableCacheKey(sourceUrl),
        DateTime.now().millisecondsSinceEpoch,
      );
      return value ?? '';
    });
  }

  /// 保存或删除 Flutter 独立缓存中的书源自定义变量。
  @override
  Future<void> saveSourceVariable(String sourceUrl, String? value) {
    return guardDataOperation<void>(() async {
      /// 与 Android `BaseSource.getVariable()` 一致的稳定缓存键。
      final String key = _sourceVariableCacheKey(sourceUrl);
      if (value == null) {
        await _cacheDao.delete(key);
        return;
      }
      await _cacheDao.upsert(Cache(key: key, value: value));
    });
  }

  /// 生成 Android `sourceVariable_书源URL` 对应的 Flutter 独立缓存键。
  String _sourceVariableCacheKey(String sourceUrl) {
    return 'sourceVariable_$sourceUrl';
  }

  /// 批量更新启用状态。
  @override
  Future<void> setEnabled(Set<String> sourceUrls, {required bool enabled}) {
    return _updateSources(
      sourceUrls,
      (BookSource source) => source.copyWithManagement(enabled: enabled),
    );
  }

  /// 批量更新分组文本。
  @override
  Future<void> setGroup(Set<String> sourceUrls, String? group) {
    return _updateSources(
      sourceUrls,
      (BookSource source) => source.copyWithManagement(bookSourceGroup: group),
    );
  }

  /// 在一个事务中读取并替换指定书源。
  Future<void> _updateSources(
    Set<String> sourceUrls,
    BookSource Function(BookSource source) transform,
  ) {
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        for (final String sourceUrl in sourceUrls) {
          /// 当前待修改书源。
          final BookSource? source = await _bookSourceDao.getByUrl(
            sourceUrl,
            executor: transaction,
          );
          if (source != null) {
            await _bookSourceDao.upsert(transform(source), executor: transaction);
          }
        }
      });
      if (sourceUrls.isNotEmpty) {
        _database.changeNotifier.notifyTables(<String>{DatabaseTables.bookSources});
      }
    });
  }

  /// 删除书源，并让外键级联清理搜索结果。
  @override
  Future<void> deleteByUrl(String sourceUrl) {
    return guardDataOperation<void>(() async {
      await _bookSourceDao.deleteByUrl(sourceUrl);
      await _cacheDao.delete(_sourceVariableCacheKey(sourceUrl));
    });
  }

  /// 原子删除多个书源及数据库外键关联的搜索缓存。
  @override
  Future<void> deleteByUrls(Set<String> sourceUrls) {
    return guardDataOperation<void>(() async {
      await _database.transaction<void>((transaction) async {
        await _bookSourceDao.deleteByUrls(sourceUrls, executor: transaction);
      });
      for (final String sourceUrl in sourceUrls) {
        await _cacheDao.delete(_sourceVariableCacheKey(sourceUrl));
      }
      if (sourceUrls.isNotEmpty) {
        _database.changeNotifier.notifyTables(
          <String>{DatabaseTables.bookSources, DatabaseTables.searchBooks},
        );
      }
    });
  }
}
