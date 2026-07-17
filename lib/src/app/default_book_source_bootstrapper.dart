import 'package:flutter/services.dart';

import '../domain/gateway/book_source_gateway.dart';
import '../domain/model/book_source.dart';
import '../domain/model/book_source_import_result.dart';
import '../domain/usecase/import_book_sources_use_case.dart';
import '../help/error/app_result.dart';
import '../help/logging/app_logger.dart';

/// 在全新 Flutter App 数据库中导入内置书源资产。
///
/// 对应 Android `app/src/main/assets/defaultData/bookSources.json` 的出厂数据语义：
/// 新安装应用第一次进入时应已经拥有可用书源，但已有用户书源时不能被启动流程覆盖。
final class DefaultBookSourceBootstrapper {
  /// 创建内置书源导入器，所有依赖都由应用组合根显式传入。
  const DefaultBookSourceBootstrapper({
    required this.sourceGateway,
    required this.importBookSources,
    required this.assetBundle,
    required this.logger,
  });

  /// Flutter assets 中保存内置书源 JSON 的稳定路径。
  static const String defaultBookSourcesAssetPath =
      'assets/default_data/book_sources.json';

  /// 读取现有书源数量的领域边界，用于避免覆盖用户已经管理过的书源。
  final BookSourceGateway sourceGateway;

  /// 复用书源管理页面同一套 JSON 解码、校验、冲突和事务导入流程。
  final ImportBookSourcesUseCase importBookSources;

  /// 启动期读取 Flutter assets 的资源入口，测试或后续平台差异可替换。
  final AssetBundle assetBundle;

  /// 启动期导入结果和失败原因使用应用统一日志记录。
  final AppLogger logger;

  /// 当书源表为空时导入内置书源；已有任意书源时跳过，保护用户数据。
  Future<void> importIfEmpty() async {
    /// 当前数据库中已经存在的用户或内置书源。
    final List<BookSource> existingSources = await sourceGateway.getAll();
    if (existingSources.isNotEmpty) {
      logger.info(
        message: '跳过内置书源导入，当前已有书源数量=${existingSources.length}',
      );
      return;
    }

    /// 从 Flutter assets 读取的原始 Android 兼容书源 JSON。
    final String sourceJson = await assetBundle.loadString(
      defaultBookSourcesAssetPath,
      cache: false,
    );
    /// 内置书源导入结果；空库场景仍使用 skip 策略防止同批重复 URL 覆盖首条。
    final AppResult<BookSourceImportResult> result =
        await importBookSources.execute(
      sourceJson,
      conflictPolicy: BookSourceConflictPolicy.skip,
    );

    if (result is AppFailure<BookSourceImportResult>) {
      logger.error(
        message: '内置书源导入失败：${result.error.message}',
        error: result.error.cause,
        stackTrace: result.error.stackTrace,
      );
      throw result.error;
    }

    if (result is AppSuccess<BookSourceImportResult>) {
      /// 可写入数据库的内置书源统计，不记录书源 URL、Header、Cookie 或规则正文。
      final BookSourceImportResult summary = result.value;
      logger.info(
        message: '内置书源导入完成 '
            'total=${summary.total} '
            'added=${summary.added} '
            'skipped=${summary.skipped} '
            'invalid=${summary.invalid}',
      );
    }
  }
}
